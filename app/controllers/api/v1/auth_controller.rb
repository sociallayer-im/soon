class Api::V1::AuthController < Api::BaseController
  # Everything here IS the login flow — only the bind_* actions run with a
  # session already in hand.
  skip_before_action :authenticate!, except: %i[bind_email bind_phone bind_wechat]

  LOGIN_CONTEXT = "login".freeze
  # Binding an email to a wallet-first account uses its own context so a bind
  # code can never be replayed as a login code (or vice versa).
  BIND_CONTEXT = "bind_email".freeze
  # Phone codes travel over a different channel to a different identifier, so
  # they get their own context for the same reason: a code texted to a phone
  # must not be redeemable as the email login code of whoever shares the digits.
  PHONE_LOGIN_CONTEXT = "phone_login".freeze
  # …and its bind counterpart, for the required "attach a phone number" step a
  # WeChat sign-in goes through. Same split, same reason as BIND_CONTEXT.
  BIND_PHONE_CONTEXT = "bind_phone".freeze
  PHONE_CONTEXTS = [ PHONE_LOGIN_CONTEXT, BIND_PHONE_CONTEXT ].freeze
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
  # sola.day joined this list on 2026-08-15 when it became the canonical
  # frontend host. app.sola.day stays: it 308s to sola.day, but a wallet
  # signature captured just before the redirect still carries the old domain.
  # The two group subdomains are separate origins as far as a wallet is
  # concerned — signing in from infinitacity.sola.day fills the SIWE `domain`
  # field with that host, so omitting them makes wallet sign-in fail there and
  # nowhere else. Any future group subdomain has to be added here too — and
  # note sonic.sola.town is not a sola.day subdomain at all but a separate
  # apex, so nothing about the existing entries would have covered it.
  #
  # This default and ALLOWED_SIWE_DOMAINS in each .env.*.production have to be
  # kept in step. The env var wins in production, so editing only this list
  # changes dev and test and nothing else; editing only the env leaves the
  # fallback wrong for any deployment that loses the variable.
  ALLOWED_SIWE_DOMAINS = ENV.fetch("ALLOWED_SIWE_DOMAINS",
    "sola.day,app.sola.day,auth.sola.day,id.sola.day,infinitacity.sola.day,edgeesmeralda.sola.day," \
    "sonic.sola.town," \
    "juluo.xyz,www.juluo.xyz,auth.juluo.xyz,id.juluo.xyz")
    .split(",").map(&:strip).map(&:downcase).reject(&:blank?).freeze
  # Bare hostname, optionally with a :port — matches how wagmi/viem's
  # `window.location.host` fills the SIWE domain field in local dev.
  LOCAL_SIWE_DOMAIN = /\A(localhost|127\.0\.0\.1)(:\d+)?\z/

  # Mainland mobile numbers only, and only ever +86. The 签名 and 模板 registered
  # with Aliyun are domestic ones; an international number would be accepted
  # here, cost a message, and be rejected by the gateway — so it is refused up
  # front. Widening this is a product decision that also needs 国际短信 enabled
  # on the Aliyun account, not just a looser regex.
  CN_MOBILE = /\A1[3-9]\d{9}\z/
  CN_COUNTRY_CODE = "+86".freeze

  # SMS costs money per message and is sent to a number the requester does not
  # have to own, which makes an unthrottled endpoint a way to bill us for
  # texting strangers. Both limits are enforced against the auth_codes table
  # rather than a cache: production configures no cache store, and a limit that
  # silently evaporates is worse than none.
  #
  # Relaxed 2026-09-23 from 60s / 5: a WeChat user whose page did not move on
  # after a successful send tapped again and hit a minute-long wall. The 429s
  # carry a `code` so the client can treat SMS_COOLDOWN as "a code is already
  # on its way" rather than as a failure.
  PHONE_CODE_INTERVAL = 30.seconds
  PHONE_CODE_HOURLY_LIMIT = 10

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

  # POST /api/v1/auth/request_phone_code
  # The SMS counterpart of #request_code. CN-only and +86-only; see
  # #phone_login_enabled? and CN_MOBILE. context=bind_phone mints a code for
  # the bind flow instead.
  def request_phone_code
    return render_not_found unless phone_login_enabled?

    phone = normalized_phone
    return render_error("invalid phone number") if phone.blank?
    return if rate_limited?(phone)

    context = params[:context] == BIND_PHONE_CONTEXT ? BIND_PHONE_CONTEXT : PHONE_LOGIN_CONTEXT
    AuthCode.active.for_recipient(phone).for_context(context).update_all(used_at: Time.current)
    code = AuthCode.create!(
      recipient: phone, recipient_type: "phone", context: context,
      code: generated_code
    )
    # Synchronous, like the emailed code: a gateway rejection (throttled,
    # template under review, account out of balance) has to reach the person
    # waiting for the text, not a log nobody reads.
    SmsSender.send_login_code(phone: phone, code: code.code)
    render json: { message: "Code sent" }
  rescue SmsSender::Error => e
    # The code was already minted and the priors already burned. Leave it
    # active — the number may well have received an earlier attempt, and a
    # valid code the user can still type is better than forcing a retry that
    # is rate-limited for the next minute.
    Rails.logger.error("[auth] SMS send failed for #{phone}: #{e.message}")
    render_error("Failed to send SMS: #{e.message}", status: :bad_gateway)
  end

  # POST /api/v1/auth/verify_phone_code — signs in, creating the account on
  # first use. A phone-first account has no email and no name, so the frontend
  # routes it to /register exactly as it does a WeChat one.
  def verify_phone_code
    return render_not_found unless phone_login_enabled?

    phone = normalized_phone
    return render_error("invalid phone number") if phone.blank?

    code = consume_code!(recipient: phone, context: PHONE_LOGIN_CONTEXT, attempt: params[:code])
    return unless code

    user = User.find_or_create_by!(phone: phone)
    GroupInvite.auto_accept_phone_invites_for(user)
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

  # POST /api/v1/auth/verify_google — Google OAuth sign-in.
  # The access token comes straight from the browser and is verified HERE
  # against Google's userinfo endpoint; only the email Google returns is used.
  # This replaces the old frontend-mediated path through #trusted_signin, which
  # required trusting a shared secret with the power to mint a session for any
  # email at all.
  def verify_google
    email = GoogleAuth.verified_email(params[:access_token].to_s)
    return render json: { error: "Invalid Google access token" }, status: :unauthorized unless email

    user = User.find_or_create_by!(email: email)
    GroupInvite.auto_accept_ticket_invites_for(user)
    render_token user
  end

  # POST /api/v1/auth/trusted_signin
  # For the frontend's WeChat 网页授权 callback ONLY: the openid is proven by the
  # frontend server redeeming the code with the app secret, so that server (and
  # only it, via NEXT_TOKEN) may assert the identity. The email and sol branches
  # this once had are gone — Google verifies in #verify_google, Solana died with
  # the standalone auth app — so NEXT_TOKEN can no longer mint a session for an
  # arbitrary email.
  def trusted_signin
    return render json: { error: "Unauthorized" }, status: :unauthorized unless next_token_ok?
    return render_error("wechat_openid is required") unless params[:wechat_openid].present? || params[:wechat_unionid].present?

    render_token wechat_user
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

  # POST /api/v1/auth/bind_phone — attaches a code-verified mobile number to the
  # account already signed in. Structurally #bind_email, including the merge:
  # this is the step a WeChat sign-in is REQUIRED to complete, so a number that
  # already has its own account (from an earlier SMS sign-in) has to resolve to
  # one account rather than dead-end the only path forward.
  def bind_phone
    return render_not_found unless phone_login_enabled?
    return render_error("phone is already set") if current_user.phone.present?

    phone = normalized_phone
    return render_error("invalid phone number") if phone.blank?
    return unless consume_code!(recipient: phone, context: BIND_PHONE_CONTEXT, attempt: params[:code])

    if (existing = User.find_by(phone: phone))
      return render_error("this phone number is already in use") unless mergeable?(current_user, existing)
      return render_token(merge_wechat_account!(current_user, existing), merged: true)
    end

    current_user.update!(phone: phone)
    GroupInvite.auto_accept_phone_invites_for(current_user)
    render json: UserBlueprint.render(current_user, view: :self)
  end

  # POST /api/v1/auth/bind_wechat  {next_token, wechat_openid, wechat_unionid?}
  #
  # Attaches a WeChat identity to the account already signed in. WeChat Pay's
  # JSAPI cannot place an order without the payer's openid, and a buyer who
  # signed in by email has none — so the frontend runs a silent snsapi_base
  # authorize and posts the result here.
  #
  # Double-gated deliberately. The JWT establishes WHICH account, but only the
  # frontend server may assert WHAT the openid is, because it is the one that
  # just redeemed the code with the app secret. Accepted on user auth alone,
  # anyone could claim a stranger's openid and thereby receive their next
  # WeChat sign-in.
  def bind_wechat
    return render json: { error: "Unauthorized" }, status: :unauthorized unless next_token_ok?

    openid = params[:wechat_openid].presence&.to_s
    unionid = params[:wechat_unionid].presence&.to_s
    return render_error("wechat_openid is required") if openid.blank?

    owner = User.find_by(wechat_openid: openid)
    owner ||= User.find_by(wechat_unionid: unionid) if unionid
    if owner && owner.id != current_user.id
      # This identity already has an account. Merging in THIS direction would
      # delete an account that may hold events, orders and memberships —
      # unlike #bind_email's window, which only ever removes a WeChat account
      # created moments ago with nothing on it. Refuse; signing in as that
      # account is the way through.
      return render_error("this WeChat account is already linked to another account")
    end

    updates = {}
    updates[:wechat_openid] = openid if claimable?(:wechat_openid, openid, current_user)
    updates[:wechat_unionid] = unionid if unionid.present? && claimable?(:wechat_unionid, unionid, current_user)
    updates.merge!(wechat_profile_updates(current_user))
    current_user.update!(updates) if updates.any?

    render json: UserBlueprint.render(current_user, view: :self)
  end

  private

  def next_token_ok?
    secret = ENV["NEXT_TOKEN"]
    # An unset NEXT_TOKEN must not authorize anyone — secure_compare("", "") is
    # true, so the blank case is guarded explicitly.
    secret.present? && ActiveSupport::SecurityUtils.secure_compare(params[:next_token].to_s, secret)
  end

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
    unless user
      return User.create!(
        wechat_openid: openid, wechat_unionid: unionid,
        nickname: params[:wechat_nickname].presence, image_url: params[:wechat_avatar_url].presence
      )
    end

    # Only ever fills a blank, and only with an identifier nobody else holds —
    # never repoints one at a different WeChat account, which would silently
    # hand one person's session to another. A conflict here means WeChat
    # returned a pairing that contradicts what we stored, which shouldn't
    # happen; the safe response is to sign in the matched account and leave
    # both identifiers where they are rather than fail the login.
    updates = {}
    updates[:wechat_openid] = openid if claimable?(:wechat_openid, openid, user)
    updates[:wechat_unionid] = unionid if claimable?(:wechat_unionid, unionid, user)
    updates.merge!(wechat_profile_updates(user))
    user.update(updates) if updates.any?
    user
  end

  # nickname/avatar are display-only (nickname is shown as the profile's
  # display name — see UserBlueprint — never as `name`, the handle/login
  # identifier, which has its own format rules and registration flow).
  # Filled from WeChat only when blank, on every sign-in/bind, so this never
  # clobbers something the person set themselves either here or on WeChat
  # before we last synced.
  def wechat_profile_updates(user)
    updates = {}
    nickname = params[:wechat_nickname].presence
    avatar_url = params[:wechat_avatar_url].presence
    updates[:nickname] = nickname if nickname && user.nickname.blank?
    updates[:image_url] = avatar_url if avatar_url && user.image_url.blank?
    updates
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
  # an in-use address goes back to being an error. (This is also why both the
  # phone and the email question come BEFORE the username step: picking a name
  # closes the window for both.)
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
    # A WeChat account can already hold a verified phone by the time it gets
    # here: binding the number is the FIRST onboarding step and the email
    # question comes after it. Dropping `from` without carrying that across
    # would silently discard a number the user has just proved they own.
    carry = {
      wechat_openid: from.wechat_openid,
      wechat_unionid: from.wechat_unionid,
      phone: (from.phone if into.phone.blank?),
      nickname: (from.nickname if into.nickname.blank?),
      image_url: (from.image_url if into.image_url.blank?)
    }.compact

    User.transaction do
      from.destroy!
      into.update!(carry)
    end
    GroupInvite.auto_accept_ticket_invites_for(into)
    # The merge may have just carried a verified phone onto `into` (see
    # `carry` above) — any whitelist invites for that number land now.
    GroupInvite.auto_accept_phone_invites_for(into)
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

  # Canonical form matters twice over: it is the AuthCode recipient (so the
  # code requested must be the code verified) and the uniquely-indexed
  # users.phone (so one person is one row however they typed it that day).
  # The rules live in PhoneNumber so the group-invite phone import normalizes
  # with the same ones.
  def normalized_phone
    PhoneNumber.normalize(params[:phone])
  end

  # Renders the 429 and returns true when the number has asked too recently or
  # too often. Counts every code minted for the number, not just live ones —
  # requesting a new code marks the previous one used, so the `active` scope
  # would see one row no matter how many were sent.
  # Counts login and bind codes together: it is one number, one gateway and one
  # bill, and a per-context limit would just be two ways to text the same person.
  def rate_limited?(phone)
    scope = AuthCode.for_recipient(phone).where(context: PHONE_CONTEXTS)

    if scope.where(created_at: PHONE_CODE_INTERVAL.ago..).exists?
      render json: { error: "Please wait a moment before requesting another code", code: "SMS_COOLDOWN" },
        status: :too_many_requests
      return true
    end

    if scope.where(created_at: 1.hour.ago..).count >= PHONE_CODE_HOURLY_LIMIT
      render json: { error: "Too many code requests, please try again later", code: "SMS_HOURLY_LIMIT" },
        status: :too_many_requests
      return true
    end

    false
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
