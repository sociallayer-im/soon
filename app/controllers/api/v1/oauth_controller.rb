# OAuth 2.0 / OpenID Connect authorization server.
#
# Error bodies here follow RFC 6749 §5.2 (`{error, error_description}` with a
# fixed set of codes) rather than soon's usual `{error: <sentence>}` — generic
# client libraries branch on those codes, and `invalid_grant` in particular is
# what tells a client to discard its refresh token instead of retrying forever.
class Api::V1::OauthController < Api::BaseController
  # The whole OAuth surface is either publicly reachable (token, userinfo,
  # revoke — which authenticate by client credentials or bearer token) or
  # authenticates the end user itself (authorize).
  skip_before_action :authenticate!
  # RFC 6749 §5.1 makes these a MUST on any response carrying a token, and
  # RFC 6750 §5.3 repeats it for the resource endpoint. Without them a proxy or
  # a browser is entitled to keep a copy of somebody's access token.
  before_action :forbid_caching, only: %i[token userinfo revoke]

  OauthError = Class.new(StandardError) do
    attr_reader :code, :status
    def initialize(code, description, status = :bad_request)
      @code = code
      @status = status
      super(description)
    end
  end

  rescue_from OauthError do |e|
    render json: { error: e.code, error_description: e.message }, status: e.status
  end

  # GET /api/v1/oauth/authorize
  #
  # Validates the request and returns what the consent screen needs to render.
  # Deliberately NOT a redirect endpoint: the consent screen is a page in the
  # web app, and having the API render HTML would put a second templating
  # surface in a JSON backend. GET /oauth/authorize at the root (see
  # WellKnownController) is the standards-compliant browser entry point that
  # bounces here.
  def authorize_info
    app = validated_authorize_request!
    scopes = requested_scopes
    grant = current_user_optional && OauthGrant.find_by(user: current_user_optional, oauth_application: app)

    render json: {
      client_id: app.client_id,
      app_name: app.name,
      app_description: app.description,
      app_logo_url: app.logo_url,
      app_homepage_url: app.homepage_url,
      # Who is actually behind this app. With no review process, this and the
      # redirect host are what a user has to judge a client by — see
      # design/OAUTH_PROVIDER_PLAN.md §9.
      owner_handle: app.group&.name || app.owner&.name,
      owner_type: app.group_id.present? ? "group" : "user",
      reviewed: app.reviewed_at.present?,
      trusted: app.trusted?,
      redirect_uri: params[:redirect_uri],
      redirect_host: URI.parse(params[:redirect_uri].to_s).host,
      scopes: scopes,
      scope_details: OauthClaims.describe(scopes),
      has_sensitive_scope: scopes.any? { |s| OauthClaims.sensitive?(s) },
      # Lets the screen offer one-click continue for scopes already granted.
      previously_granted: grant&.scopes || [],
      # A trusted first-party client, or a repeat visit that adds no new scope,
      # needs no consent interaction. `trusted` is settable in the database
      # only, never through the API.
      can_skip_consent: app.trusted? || (grant.present? && grant.covers?(scopes))
    }
  end

  # POST /api/v1/oauth/authorize
  #
  # The signed-in user accepts or denies. Returns the code (or the error) for
  # the frontend to append to the redirect_uri — the browser, not the API,
  # performs the navigation.
  def authorize_decision
    user = current_user_required!
    app = find_application!(params[:client_id])

    if params[:decision].to_s == "deny"
      # The redirect_uri must be validated even on the denial path, or this
      # endpoint becomes an open redirect that any client_id can aim anywhere.
      validate_redirect_uri!(app, params[:redirect_uri])
      return render json: {
        redirect_uri: params[:redirect_uri], error: "access_denied", state: params[:state]
      }
    end

    validated_authorize_request!(app)
    scopes = requested_scopes

    code = nil
    ActiveRecord::Base.transaction do
      OauthGrant.upsert_for(user: user, application: app, scopes: scopes)
      record = OauthAuthorizationCode.issue(
        user: user, application: app, scopes: scopes,
        redirect_uri: params[:redirect_uri],
        code_challenge: params[:code_challenge],
        nonce: params[:nonce]
      )
      code = record.plaintext_token
    end

    render json: { code: code, redirect_uri: params[:redirect_uri], state: params[:state] }
  end

  # POST /api/v1/oauth/token
  def token
    case params[:grant_type]
    when "authorization_code" then authorization_code_grant
    when "refresh_token"      then refresh_token_grant
    else
      raise OauthError.new("unsupported_grant_type", "grant_type must be authorization_code or refresh_token")
    end
  end

  # GET /api/v1/oauth/userinfo
  def userinfo
    at = access_token!
    render json: OauthClaims.new(at.user, at.scopes).to_h.merge(scope: at.scopes.join(" "))
  end

  # POST /api/v1/oauth/revoke — RFC 7009
  def revoke
    app = authenticated_client!
    value = params[:token].to_s

    # Scoped to the calling client, so one app cannot revoke another's tokens.
    if (at = OauthAccessToken.find_by_token(value)) && at.application_id == app.id
      at.revoke!
    elsif (rt = OauthRefreshToken.find_by_token(value)) && rt.application_id == app.id
      # Revoking a refresh token kills the whole chain: a client asking to
      # forget a session means the session, not one link of it.
      rt.burn_family!
    end

    # RFC 7009 §2.2: an unknown token is a success. Anything else turns this
    # endpoint into a token-validity oracle.
    render json: { result: "ok" }
  end

  private

  # --- grants -------------------------------------------------------------

  def authorization_code_grant
    app = authenticated_client!
    raise OauthError.new("invalid_client", "Application is not active") unless app.status == "active"

    record = OauthAuthorizationCode.find_by_token(params[:code])
    raise OauthError.new("invalid_grant", "Invalid or expired authorization code") if record.nil?
    raise OauthError.new("invalid_grant", "Authorization code was issued to another client") unless record.application_id == app.id

    # Atomic claim. Two simultaneous exchanges of the same code both reach this
    # line; exactly one UPDATE matches a row with used_at IS NULL, so exactly
    # one proceeds. Checking-then-updating in Ruby would let both through.
    claimed = OauthAuthorizationCode.unused.where(id: record.id).update_all(used_at: Time.current)
    if claimed.zero?
      # A code presented twice means it leaked (or the client is broken). The
      # tokens it already produced are no longer trustworthy — RFC 6819 §5.2.1.1.
      revoke_tokens_from_code(record)
      raise OauthError.new("invalid_grant", "Authorization code already used or expired")
    end

    unless record.redirect_uri == params[:redirect_uri]
      raise OauthError.new("invalid_grant", "redirect_uri does not match the authorization request")
    end
    unless record.pkce_valid?(params[:code_verifier])
      raise OauthError.new("invalid_grant", "code_verifier does not match code_challenge")
    end

    access = OauthAccessToken.issue(user: record.user, application: app, scopes: record.scopes)
    refresh = OauthRefreshToken.issue(user: record.user, application: app, access_token: access)

    render json: token_response(access, refresh, user: record.user, application: app, nonce: record.nonce)
  end

  def refresh_token_grant
    app = authenticated_client!
    raise OauthError.new("invalid_client", "Application is not active") unless app.status == "active"

    rt = OauthRefreshToken.find_by_token(params[:refresh_token])
    raise OauthError.new("invalid_grant", "Unknown refresh_token") if rt.nil?
    raise OauthError.new("invalid_grant", "refresh_token was issued to another client") unless rt.application_id == app.id

    if rt.revoked_at.present?
      # Reuse detection: the legitimate client and someone else both hold this
      # chain, and there is no way to tell which one is calling. Burn it all.
      rt.burn_family!
      raise OauthError.new("invalid_grant", "refresh_token has already been used")
    end
    raise OauthError.new("invalid_grant", "refresh_token has expired") unless rt.active?

    # RFC 6749 §6: a client may ask for a subset of what it was granted, and
    # MUST NOT be able to widen. Omitting scope means "the same as before".
    narrowed = requested_scopes
    if narrowed.any?
      extra = narrowed - rt.oauth_access_token.scopes
      raise OauthError.new("invalid_scope", "Scopes exceed the original grant: #{extra.join(', ')}") if extra.any?
    end

    access, refresh = rt.rotate!(scopes: narrowed.presence)
    render json: token_response(access, refresh, user: rt.user, application: app)
  end

  def revoke_tokens_from_code(record)
    OauthAccessToken.where(user_id: record.user_id, application_id: record.application_id)
                    .where(revoked_at: nil).find_each(&:revoke!)
  end

  def token_response(access, refresh, user:, application:, nonce: nil)
    body = {
      access_token: access.plaintext_token,
      token_type: "Bearer",
      expires_in: OauthAccessToken::TTL.to_i,
      refresh_token: refresh.plaintext_token,
      scope: access.scopes.join(" ")
    }
    if access.scopes.include?("openid")
      # The discovery document promises OIDC, so a request for the openid scope
      # must produce an id_token or fail loudly. Silently returning a token
      # response without one leaves a standards-compliant client failing with
      # an error that names neither this server nor the missing key — exactly
      # the kind of misconfiguration that gets found in production.
      unless OauthConfig.configured?
        raise OauthError.new("server_error", "OAUTH_RSA_PRIVATE_KEY is not configured on this deployment", :internal_server_error)
      end
      body[:id_token] = OauthIdToken.encode(
        user: user, application: application, scopes: access.scopes, nonce: nonce
      )
    end
    body
  end

  # --- authentication -----------------------------------------------------

  # Client authentication for the token/revoke endpoints. Confidential clients
  # present a secret (Basic per RFC 6749 §2.3.1, or form-encoded); public ones
  # present only their client_id and rely on PKCE, which is why they may not
  # have a secret at all.
  def authenticated_client!
    client_id, secret = basic_client_credentials
    client_id = params[:client_id] if client_id.blank?
    secret = params[:client_secret] if secret.blank?

    app = find_application!(client_id)
    return app unless app.confidential?
    raise OauthError.new("invalid_client", "Invalid client credentials", :unauthorized) unless app.authenticate_secret(secret)
    app
  end

  def basic_client_credentials
    header = request.headers["Authorization"].to_s
    return [ nil, nil ] unless header.start_with?("Basic ")
    decoded = Base64.decode64(header.split(" ", 2).last.to_s)
    id, secret = decoded.split(":", 2)
    [ CGI.unescape(id.to_s), CGI.unescape(secret.to_s) ]
  rescue ArgumentError
    [ nil, nil ]
  end

  # The bearer token on userinfo is an OAuth access token, NOT a sola session
  # JWT. Keeping the two apart is the point: a third party holding a scoped
  # OAuth token must never be able to call the rest of /api/v1 with it.
  def access_token!
    header = request.headers["Authorization"].to_s
    unless header.start_with?("Bearer ")
      # RFC 6750 §3: a 401 from a resource endpoint has to say what scheme it
      # wants, or a client cannot tell "wrong credentials" from "no idea".
      response.headers["WWW-Authenticate"] = "Bearer"
      raise OauthError.new("invalid_request", "Missing bearer token", :unauthorized)
    end

    value = header.split(" ", 2).last
    at = OauthAccessToken.find_by_token(value)
    unless at&.active?
      response.headers["WWW-Authenticate"] = 'Bearer error="invalid_token"'
      raise OauthError.new("invalid_token", "Invalid or expired access token", :unauthorized)
    end
    raise OauthError.new("invalid_token", "Application is disabled", :unauthorized) unless at.oauth_application.status == "active"
    at
  end

  # The end user's own session, from soon's normal JWT.
  def current_user_optional
    return @current_user_optional if defined?(@current_user_optional)
    @current_user_optional = begin
      token = bearer_token
      token.present? ? user_from_payload(JwtService.decode(token)) : nil
    rescue JwtService::Error
      nil
    end
  end

  def current_user_required!
    current_user_optional ||
      raise(OauthError.new("login_required", "Sign in required", :unauthorized))
  end

  def forbid_caching
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
  end

  # --- request validation -------------------------------------------------

  def validated_authorize_request!(app = nil)
    app ||= find_application!(params[:client_id])
    raise OauthError.new("unauthorized_client", "Application is not active") unless app.status == "active"
    validate_redirect_uri!(app, params[:redirect_uri])
    raise OauthError.new("unsupported_response_type", "response_type must be 'code'") unless params[:response_type].to_s == "code"

    # PKCE is mandatory for every client, public and confidential alike. There
    # is no legacy client to accommodate — this server has never issued a code
    # without it.
    raise OauthError.new("invalid_request", "code_challenge is required") if params[:code_challenge].blank?
    unless params[:code_challenge_method].to_s == "S256"
      raise OauthError.new("invalid_request", "code_challenge_method must be S256")
    end

    scopes = requested_scopes
    raise OauthError.new("invalid_scope", "scope is required") if scopes.empty?
    unknown = scopes - OauthApplication::VALID_SCOPES
    raise OauthError.new("invalid_scope", "Unknown scopes: #{unknown.join(', ')}") if unknown.any?
    raise OauthError.new("invalid_scope", "Scopes not allowed for this client") unless app.scopes_allowed?(scopes)

    app
  end

  def requested_scopes = params[:scope].to_s.split(/\s+/).reject(&:blank?).uniq

  def find_application!(client_id)
    app = OauthApplication.find_by(client_id: client_id.to_s)
    app || raise(OauthError.new("invalid_client", "Unknown client_id", :unauthorized))
  end

  def validate_redirect_uri!(app, uri)
    raise OauthError.new("invalid_request", "redirect_uri is required") if uri.blank?
    raise OauthError.new("invalid_request", "redirect_uri is not registered for this client") unless app.redirect_uri_allowed?(uri)
  end
end
