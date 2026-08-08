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
      code: generated_code
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

    nonce_code = AuthCode.active_nonce.for_context(SIWE_CONTEXT).find_by(code: message.nonce)
    return render json: { error: "Invalid or expired nonce" }, status: :unauthorized unless nonce_code

    # domain/nonce are passed through as the "expected" values here purely to
    # satisfy the gem's required kwargs — they're the message's own fields, so
    # those two checks are trivially self-matching. The real protection is
    # above (domain allowlist) and in the nonce_code lookup (single-use,
    # server-minted, AuthCode::NONCE_EXPIRY TTL — deliberately shorter than the
    # emailed-code EXPIRY) — not in anything siwe-rb's verify! itself
    # checks (it has no knowledge of our allowlist or minted nonces).
    message.verify!(signature: params[:signature].to_s, domain: message.domain, nonce: message.nonce)
    nonce_code.mark_used!

    render_token User.find_or_create_by!(eth: message.address.downcase)
  rescue Siwe::Error
    render json: { error: "Invalid SIWE message or signature" }, status: :unauthorized
  end

  # POST /api/v1/auth/trusted_signin
  # For the auth frontend's server-side flows (Google OAuth, Solana signature,
  # WeChat 网页授权), where the proof is verified by the frontend server itself.
  # Gated by the NEXT_TOKEN shared secret, which only that server knows.
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
    elsif params[:wechat_openid].present? || params[:wechat_unionid].present?
      render_token wechat_user
    else
      render_error("email, sol_address or wechat_openid is required")
    end
  end

  # POST /api/v1/auth/bind_email — attaches an email to a wallet- or WeChat-first
  # account after the owner proves control of it with a bind-context code. The
  # email is the login identity, so it can only be set once.
  #
  # When the address already belongs to another account this MERGES rather than
  # failing, but only in the narrow case #mergeable? allows: signing in through
  # a second channel shouldn't strand someone with two accounts, which is the
  # whole point of asking a WeChat user for their email. A merge changes who
  # the caller is, so it answers with a fresh token instead of a profile.
  def bind_email
    return render_error("email is already set") if current_user.email.present?

    email = normalized_email
    return unless consume_code!(recipient: email, context: BIND_CONTEXT, attempt: params[:code])

    if (existing = User.find_by(email: email))
      return render_error("email is already in use") unless mergeable?(current_user, existing)
      return render_token(merge_wechat_account!(current_user, existing), merged: true)
    end

    current_user.update!(email: email)
    GroupInvite.auto_accept_ticket_invites_for(current_user)
    render json: UserBlueprint.render(current_user, view: :self)
  end

  private

  # Resolves the WeChat identity the frontend just verified to an account.
  #
  # unionid wins when we have it: it is the same person across every app under
  # our 微信开放平台 account, while openid is per-appid. An account created from an
  # openid alone — before the 开放平台 binding existed, or from a scope that
  # doesn't return unionid — is claimed and back-filled on the first sign-in
  # that does carry one, so the same person never ends up with two rows.
  def wechat_user
    openid = params[:wechat_openid].presence&.to_s
    unionid = params[:wechat_unionid].presence&.to_s

    user = User.find_by(wechat_unionid: unionid) if unionid
    user ||= User.find_by(wechat_openid: openid) if openid
    return User.create!(wechat_openid: openid, wechat_unionid: unionid) unless user

    # Only ever fills a blank, and only with an identifier nobody else holds —
    # never repoints one at a different WeChat account, which would silently
    # hand one person's session to another. A conflict here means WeChat
    # returned a pairing that contradicts what we stored, which shouldn't
    # happen; the safe response is to sign in the matched account and leave
    # both identifiers where they are rather than fail the login.
    updates = {}
    updates[:wechat_openid] = openid if claimable?(:wechat_openid, openid, user)
    updates[:wechat_unionid] = unionid if claimable?(:wechat_unionid, unionid, user)
    user.update(updates) if updates.any?
    user
  end

  def claimable?(column, value, user)
    value.present? && user[column].blank? && !User.exists?(column => value)
  end

  # Merging DELETES `from`, so it is only allowed while that account cannot yet
  # hold anything worth keeping.
  #
  # `name` is the registration marker. A WeChat account is created without one
  # and the frontend sends the user straight to /register to pick it, so a blank
  # name means "signed in moments ago, never finished signing up" — exactly the
  # window this is for. Once a name is set the account is a real one and binding
  # an in-use address goes back to being an error. (This is also why the email
  # question has to come BEFORE the username step: picking a name closes the
  # window.)
  #
  # Deliberately restricted to WeChat-first accounts. Nothing server-side
  # requires a name before writing — EventPolicy#create? never looks at it — so
  # a long-lived wallet account whose owner simply never registered one would
  # otherwise qualify and be deleted along with its events and RSVPs.
  #
  # `into` must carry no WeChat identity of its own: overwriting one would aim
  # a different person's next WeChat login at this account, and refusing to
  # move ours would leave the duplicate we're here to prevent.
  def mergeable?(from, into)
    (from.wechat_openid.present? || from.wechat_unionid.present?) &&
      from.name.blank? &&
      into.wechat_openid.blank? && into.wechat_unionid.blank?
  end

  # Moves the WeChat identity onto the account that owns the email, then drops
  # the throwaway one. Order matters: both identity columns are uniquely
  # indexed, so `from` has to be gone before `into` can take them.
  def merge_wechat_account!(from, into)
    openid = from.wechat_openid
    unionid = from.wechat_unionid
    User.transaction do
      from.destroy!
      into.update!(wechat_openid: openid, wechat_unionid: unionid)
    end
    GroupInvite.auto_accept_ticket_invites_for(into)
    into
  end

  # Six digits, zero-padded so every code is the same length. rjust is not
  # cosmetic: random_number can return 42, and an unpadded "42" would be a
  # 2-digit code the fixed-length input never lets the user finish typing.
  #
  # Digits only — the codes are read off a phone and typed back, mostly inside
  # the WeChat browser. That drops the keyspace from 36^6 (~2.2e9) for the old
  # alphanumeric to 10^6, so the guardrails around it carry more weight and must
  # not be relaxed: a code dies after MAX_ATTEMPTS (5) wrong guesses, expires
  # after AuthCode::EXPIRY, and requesting a new one invalidates every earlier
  # unused code. An attacker therefore gets 5 tries per code (1-in-200,000) and
  # each retry costs the victim a visible email. Rate-limiting #request_code
  # itself is the obvious next step and does not exist yet.
  def generated_code
    SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
  end

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

  # `merged` tells the caller its session just became a DIFFERENT account, so
  # the client must replace its stored token rather than keep the one it sent.
  def render_token(user, merged: false)
    user.update(last_signin_at: Time.current)
    token = JwtService.encode({ "user_id" => user.id })
    payload = { token: token, user: { id: user.id, email: user.email, name: user.name } }
    payload[:merged] = true if merged
    render json: payload
  end
end
