class Api::V1::AuthController < Api::BaseController
  # Everything here IS the login flow — only bind_email runs with a session.
  skip_before_action :authenticate!, except: :bind_email

  LOGIN_CONTEXT = "login".freeze
  # Binding an email to a wallet-first account uses its own context so a bind
  # code can never be replayed as a login code (or vice versa).
  BIND_CONTEXT = "bind_email".freeze
  # SIWE nonces are stored server-side (as AuthCodes) so a signed message can
  # only be redeemed once — nonce reuse/replay is rejected.
  SIWE_CONTEXT = "siwe_nonce".freeze

  # This API serves multiple frontend hosts by design (SG + CN auth apps), so
  # there's no single "our host" to compare against — instead the SIWE
  # `domain` field (what the user's wallet actually displayed while signing)
  # must be one of these known-legitimate frontends. Without this check,
  # `Siwe::Message#verify`'s own domain check is meaningless here (see
  # #verify_wallet) and any domain string would be accepted.
  # The default matters: SG's ginger.yml did not inject this variable for a
  # while, so production ran on whatever was written here.
  ALLOWED_SIWE_DOMAINS = ENV.fetch("ALLOWED_SIWE_DOMAINS",
    "app.sola.day,auth.sola.day,id.sola.day,www.juluo.xyz,auth.juluo.xyz,id.juluo.xyz")
    .split(",").map(&:strip).map(&:downcase).reject(&:blank?).freeze
  # Bare hostname, optionally with a :port — matches how wagmi/viem's
  # `window.location.host` fills the SIWE domain field in local dev.
  LOCAL_SIWE_DOMAIN = /\A(localhost|127\.0\.0\.1)(:\d+)?\z/

  # POST /api/v1/auth/request_code
  # Sends a one-time code to any well-formed email — unknown addresses sign UP
  # on verify. context=bind_email mints a code for the bind flow instead.
  def request_code
    email = normalized_email
    return render_error("invalid email") unless email.match?(URI::MailTo::EMAIL_REGEXP)

    context = params[:context] == BIND_CONTEXT ? BIND_CONTEXT : LOGIN_CONTEXT
    # Only the latest code stays valid — invalidate any prior unused codes
    # so an attacker can't stack many concurrently-guessable codes.
    AuthCode.active.for_recipient(email).for_context(context).update_all(used_at: Time.current)
    code = AuthCode.create!(
      recipient: email, recipient_type: "email", context: context,
      code: SecureRandom.alphanumeric(6).upcase
    )
    # Sent synchronously so a delivery failure surfaces on this request.
    AuthMailer.login_code(email: email, code: code.code).deliver_now
    render json: { message: "Code sent" }
  end

  # POST /api/v1/auth/verify_code — signs in, creating the account on first login.
  def verify_code
    email = normalized_email
    code = consume_code!(recipient: email, context: LOGIN_CONTEXT, attempt: params[:code])
    return unless code

    user = User.find_or_create_by!(email: email)
    GroupInvite.auto_accept_ticket_invites_for(user)
    render_token user
  end

  # GET /api/v1/auth/nonce — mints a single-use SIWE nonce.
  def nonce
    value = SecureRandom.hex(16)
    AuthCode.create!(recipient: "siwe", recipient_type: "nonce", context: SIWE_CONTEXT, code: value)
    render json: { nonce: value }
  end

  # POST /api/v1/auth/verify_wallet — Sign-In with Ethereum.
  # Expects the raw EIP-4361 message and its signature; the message's nonce
  # must be one we minted (and not yet redeemed).
  def verify_wallet
    message = Siwe::Message.parse(params[:message].to_s)

    unless siwe_domain_allowed?(message.domain)
      return render json: { error: "Invalid or expired nonce" }, status: :unauthorized
    end

    nonce_code = AuthCode.active.for_context(SIWE_CONTEXT).find_by(code: message.nonce)
    return render json: { error: "Invalid or expired nonce" }, status: :unauthorized unless nonce_code

    # domain/nonce are passed through as the "expected" values here purely to
    # satisfy the gem's required kwargs — they're the message's own fields, so
    # those two checks are trivially self-matching. The real protection is
    # above (domain allowlist) and in the nonce_code lookup (single-use,
    # server-minted, 15-minute TTL) — not in anything siwe-rb's verify! itself
    # checks (it has no knowledge of our allowlist or minted nonces).
    message.verify!(signature: params[:signature].to_s, domain: message.domain, nonce: message.nonce)
    nonce_code.mark_used!

    render_token User.find_or_create_by!(eth: message.address.downcase)
  rescue Siwe::Error
    render json: { error: "Invalid SIWE message or signature" }, status: :unauthorized
  end

  # POST /api/v1/auth/trusted_signin
  # For the auth frontend's server-side flows (Google OAuth, Solana signature),
  # where the proof is verified by the auth service itself. Gated by the
  # NEXT_TOKEN shared secret, which only that server knows.
  def trusted_signin
    secret = ENV["NEXT_TOKEN"]
    unless secret.present? && ActiveSupport::SecurityUtils.secure_compare(params[:next_token].to_s, secret)
      return render json: { error: "Unauthorized" }, status: :unauthorized
    end

    if params[:email].present?
      user = User.find_or_create_by!(email: params[:email].to_s.strip.downcase)
      GroupInvite.auto_accept_ticket_invites_for(user)
      render_token user
    elsif params[:sol_address].present?
      render_token User.find_or_create_by!(sol: params[:sol_address].to_s)
    else
      render_error("email or sol_address is required")
    end
  end

  # POST /api/v1/auth/bind_email — attaches an email to a wallet-first account
  # after the owner proves control of it with a bind-context code. The email is
  # the login identity, so it can only be set once, and never to an address
  # that already belongs to another account.
  def bind_email
    return render_error("email is already set") if current_user.email.present?

    email = normalized_email
    return unless consume_code!(recipient: email, context: BIND_CONTEXT, attempt: params[:code])
    return render_error("email is already in use") if User.exists?(email: email)

    current_user.update!(email: email)
    GroupInvite.auto_accept_ticket_invites_for(current_user)
    render json: UserBlueprint.render(current_user, view: :self)
  end

  private

  def normalized_email
    params[:email].to_s.strip.downcase
  end

  def siwe_domain_allowed?(domain)
    domain = domain.to_s.downcase
    return true if ALLOWED_SIWE_DOMAINS.include?(domain)
    return true if !Rails.env.production? && domain.match?(LOCAL_SIWE_DOMAIN)

    false
  end

  # Finds the newest active code for the recipient/context and checks the
  # attempt against it, counting failures. Renders 401 and returns nil when the
  # attempt doesn't hold up; marks the code used and returns it when it does.
  def consume_code!(recipient:, context:, attempt:)
    code = AuthCode.active.for_recipient(recipient).for_context(context).order(created_at: :desc).first
    unless code
      render json: { error: "Invalid or expired code" }, status: :unauthorized
      return nil
    end

    unless ActiveSupport::SecurityUtils.secure_compare(code.code, attempt.to_s.upcase)
      code.register_failed_attempt!
      render json: { error: "Invalid or expired code" }, status: :unauthorized
      return nil
    end

    code.mark_used!
    code
  end

  def render_token(user)
    user.update(last_signin_at: Time.current)
    token = JwtService.encode({ "user_id" => user.id })
    render json: { token: token, user: { id: user.id, email: user.email, name: user.name } }
  end
end
