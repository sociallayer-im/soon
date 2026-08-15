require "test_helper"

class Api::V1::OauthControllerTest < ActionDispatch::IntegrationTest
  # A fixed verifier/challenge pair, so the PKCE assertions test the server's
  # arithmetic rather than repeating it.
  VERIFIER = "a" * 43
  CHALLENGE = Base64.urlsafe_encode64(Digest::SHA256.digest(VERIFIER), padding: false)
  REDIRECT = "https://client.example.com/callback"

  def setup
    @user = create_user
    @client, @secret = create_oauth_application(allowed_scopes: %w[openid profile email tickets:read])
  end

  def authorize_params(**overrides)
    {
      client_id: @client.client_id,
      redirect_uri: REDIRECT,
      response_type: "code",
      scope: "openid profile",
      code_challenge: CHALLENGE,
      code_challenge_method: "S256"
    }.merge(overrides)
  end

  # Runs consent + exchange and returns the parsed token response.
  def complete_flow(scope: "openid profile", user: @user)
    post "/api/v1/oauth/authorize", params: authorize_params(scope: scope, decision: "allow"),
         headers: auth_headers(user)
    assert_response :success
    code = json_response["code"]

    post "/api/v1/oauth/token", params: {
      grant_type: "authorization_code", code: code, redirect_uri: REDIRECT,
      client_id: @client.client_id, client_secret: @secret, code_verifier: VERIFIER
    }
    assert_response :success
    json_response
  end

  # --- authorize (info) ---------------------------------------------------

  test "authorize_info returns consent details without requiring a session" do
    get "/api/v1/oauth/authorize", params: authorize_params
    assert_response :success
    assert_equal @client.client_id, json_response["client_id"]
    assert_equal %w[openid profile], json_response["scopes"]
    assert_equal "client.example.com", json_response["redirect_host"]
    assert_equal @client.owner.name, json_response["owner_handle"]
    assert_equal false, json_response["can_skip_consent"]
    assert_equal 2, json_response["scope_details"].size
  end

  test "authorize_info flags tickets:read as sensitive" do
    get "/api/v1/oauth/authorize", params: authorize_params(scope: "openid tickets:read")
    assert_response :success
    assert_equal true, json_response["has_sensitive_scope"]
  end

  test "authorize_info rejects an unregistered redirect_uri" do
    get "/api/v1/oauth/authorize", params: authorize_params(redirect_uri: "https://evil.example.com/cb")
    assert_response :bad_request
    assert_equal "invalid_request", json_response["error"]
  end

  test "authorize_info rejects a missing code_challenge" do
    get "/api/v1/oauth/authorize", params: authorize_params.except(:code_challenge)
    assert_response :bad_request
    assert_equal "invalid_request", json_response["error"]
  end

  test "authorize_info rejects scopes the client is not allowed" do
    get "/api/v1/oauth/authorize", params: authorize_params(scope: "openid wallet")
    assert_response :bad_request
    assert_equal "invalid_scope", json_response["error"]
  end

  test "authorize_info rejects an inactive application" do
    @client.update!(status: "draft")
    get "/api/v1/oauth/authorize", params: authorize_params
    assert_response :bad_request
    assert_equal "unauthorized_client", json_response["error"]
  end

  test "authorize_info reports a previous grant so consent can be skipped" do
    OauthGrant.upsert_for(user: @user, application: @client, scopes: %w[openid profile])
    get "/api/v1/oauth/authorize", params: authorize_params, headers: auth_headers(@user)
    assert_response :success
    assert_equal true, json_response["can_skip_consent"]
    assert_equal %w[openid profile], json_response["previously_granted"]
  end

  # --- authorize (decision) -----------------------------------------------

  test "authorize_decision requires a signed-in user" do
    post "/api/v1/oauth/authorize", params: authorize_params(decision: "allow")
    assert_response :unauthorized
    assert_equal "login_required", json_response["error"]
  end

  test "authorize_decision issues a code and records the grant" do
    assert_difference -> { OauthGrant.count }, 1 do
      post "/api/v1/oauth/authorize", params: authorize_params(decision: "allow", state: "xyz"),
           headers: auth_headers(@user)
    end
    assert_response :success
    assert json_response["code"].present?
    assert_equal "xyz", json_response["state"]
    # Only the digest is stored — the plaintext code must not be recoverable.
    assert_nil OauthAuthorizationCode.find_by(token_digest: json_response["code"])
    assert OauthAuthorizationCode.find_by_token(json_response["code"])
  end

  test "authorize_decision deny returns access_denied and no code" do
    post "/api/v1/oauth/authorize", params: authorize_params(decision: "deny", state: "xyz"),
         headers: auth_headers(@user)
    assert_response :success
    assert_equal "access_denied", json_response["error"]
    assert_nil json_response["code"]
    assert_equal 0, OauthAuthorizationCode.count
  end

  test "authorize_decision deny still validates redirect_uri" do
    # Otherwise the denial path is an open redirect: any client_id could aim a
    # user at an arbitrary host.
    post "/api/v1/oauth/authorize",
         params: authorize_params(decision: "deny", redirect_uri: "https://evil.example.com/cb"),
         headers: auth_headers(@user)
    assert_response :bad_request
    assert_equal "invalid_request", json_response["error"]
  end

  # --- token: authorization_code ------------------------------------------

  test "authorization_code grant returns an access and refresh token" do
    body = complete_flow
    assert body["access_token"].present?
    assert body["refresh_token"].present?
    assert_equal "Bearer", body["token_type"]
    assert_equal OauthAccessToken::TTL.to_i, body["expires_in"]
    assert_equal "openid profile", body["scope"]
  end

  test "access token is stored only as a digest" do
    body = complete_flow
    assert_nil OauthAccessToken.find_by(token_digest: body["access_token"])
    assert OauthAccessToken.find_by_token(body["access_token"])
  end

  test "authorization_code grant rejects a wrong code_verifier" do
    post "/api/v1/oauth/authorize", params: authorize_params(decision: "allow"), headers: auth_headers(@user)
    code = json_response["code"]

    post "/api/v1/oauth/token", params: {
      grant_type: "authorization_code", code: code, redirect_uri: REDIRECT,
      client_id: @client.client_id, client_secret: @secret, code_verifier: "b" * 43
    }
    assert_response :bad_request
    assert_equal "invalid_grant", json_response["error"]
  end

  test "authorization_code grant rejects a mismatched redirect_uri" do
    post "/api/v1/oauth/authorize", params: authorize_params(decision: "allow"), headers: auth_headers(@user)
    code = json_response["code"]

    post "/api/v1/oauth/token", params: {
      grant_type: "authorization_code", code: code, redirect_uri: "https://client.example.com/other",
      client_id: @client.client_id, client_secret: @secret, code_verifier: VERIFIER
    }
    assert_response :bad_request
    assert_equal "invalid_grant", json_response["error"]
  end

  test "authorization_code grant rejects a bad client_secret" do
    post "/api/v1/oauth/authorize", params: authorize_params(decision: "allow"), headers: auth_headers(@user)
    code = json_response["code"]

    post "/api/v1/oauth/token", params: {
      grant_type: "authorization_code", code: code, redirect_uri: REDIRECT,
      client_id: @client.client_id, client_secret: "wrong", code_verifier: VERIFIER
    }
    assert_response :unauthorized
    assert_equal "invalid_client", json_response["error"]
  end

  test "replaying an authorization code revokes the tokens it already produced" do
    post "/api/v1/oauth/authorize", params: authorize_params(decision: "allow"), headers: auth_headers(@user)
    code = json_response["code"]
    exchange = -> {
      post "/api/v1/oauth/token", params: {
        grant_type: "authorization_code", code: code, redirect_uri: REDIRECT,
        client_id: @client.client_id, client_secret: @secret, code_verifier: VERIFIER
      }
    }

    exchange.call
    assert_response :success
    access = OauthAccessToken.find_by_token(json_response["access_token"])
    assert access.active?

    exchange.call
    assert_response :bad_request
    assert_equal "invalid_grant", json_response["error"]
    assert_not access.reload.active?
  end

  test "a code issued to one client cannot be redeemed by another" do
    other_app, other_secret = create_oauth_application
    post "/api/v1/oauth/authorize", params: authorize_params(decision: "allow"), headers: auth_headers(@user)
    code = json_response["code"]

    post "/api/v1/oauth/token", params: {
      grant_type: "authorization_code", code: code, redirect_uri: REDIRECT,
      client_id: other_app.client_id, client_secret: other_secret, code_verifier: VERIFIER
    }
    assert_response :bad_request
    assert_equal "invalid_grant", json_response["error"]
    # And the code survives for its rightful owner.
    assert_nil OauthAuthorizationCode.find_by_token(code).used_at
  end

  test "an expired authorization code is rejected" do
    post "/api/v1/oauth/authorize", params: authorize_params(decision: "allow"), headers: auth_headers(@user)
    code = json_response["code"]
    OauthAuthorizationCode.find_by_token(code).update!(expires_at: 1.second.ago)

    post "/api/v1/oauth/token", params: {
      grant_type: "authorization_code", code: code, redirect_uri: REDIRECT,
      client_id: @client.client_id, client_secret: @secret, code_verifier: VERIFIER
    }
    assert_response :bad_request
    assert_equal "invalid_grant", json_response["error"]
  end

  test "a public client authenticates with PKCE and no secret" do
    public_app, secret = create_oauth_application(confidential: false, allowed_scopes: %w[openid profile])
    assert_nil secret

    post "/api/v1/oauth/authorize",
         params: authorize_params(client_id: public_app.client_id, decision: "allow"),
         headers: auth_headers(@user)
    assert_response :success

    post "/api/v1/oauth/token", params: {
      grant_type: "authorization_code", code: json_response["code"], redirect_uri: REDIRECT,
      client_id: public_app.client_id, code_verifier: VERIFIER
    }
    assert_response :success
    assert json_response["access_token"].present?
  end

  test "client credentials are accepted via HTTP Basic" do
    post "/api/v1/oauth/authorize", params: authorize_params(decision: "allow"), headers: auth_headers(@user)
    code = json_response["code"]

    basic = Base64.strict_encode64("#{@client.client_id}:#{@secret}")
    post "/api/v1/oauth/token",
         params: { grant_type: "authorization_code", code: code, redirect_uri: REDIRECT, code_verifier: VERIFIER },
         headers: { "Authorization" => "Basic #{basic}" }
    assert_response :success
    assert json_response["access_token"].present?
  end

  test "an id_token is issued for the openid scope and verifies against the JWKS" do
    with_oauth_signing_key do
      body = complete_flow
      assert body["id_token"].present?

      claims, header = JWT.decode(body["id_token"], OauthConfig.public_key, true, algorithm: "RS256")
      assert_equal "RS256", header["alg"]
      assert_equal OauthConfig.key_id, header["kid"]
      assert_equal @user.id, claims["sub"]
      assert_equal @client.client_id, claims["aud"]
      assert_equal OauthConfig.issuer, claims["iss"]
    end
  end

  test "the id_token carries the nonce back" do
    with_oauth_signing_key do
      post "/api/v1/oauth/authorize", params: authorize_params(decision: "allow", nonce: "n-123"),
           headers: auth_headers(@user)
      post "/api/v1/oauth/token", params: {
        grant_type: "authorization_code", code: json_response["code"], redirect_uri: REDIRECT,
        client_id: @client.client_id, client_secret: @secret, code_verifier: VERIFIER
      }
      claims, = JWT.decode(json_response["id_token"], OauthConfig.public_key, true, algorithm: "RS256")
      assert_equal "n-123", claims["nonce"]
    end
  end

  test "no id_token is issued without the openid scope" do
    with_oauth_signing_key do
      body = complete_flow(scope: "profile")
      assert_nil body["id_token"]
    end
  end

  test "an id_token is signed even without OAUTH_RSA_PRIVATE_KEY outside production" do
    # Dev and test mint an ephemeral key rather than half-answering: the
    # discovery document promises OIDC either way, so "no id_token" would be a
    # confusing thing to debug locally. Production does NOT do this — see
    # OauthConfig.private_key.
    body = complete_flow
    assert body["id_token"].present?
  end

  # --- token: refresh_token ------------------------------------------------

  test "refresh rotates both tokens and burns the old pair" do
    body = complete_flow
    old_access = body["access_token"]
    old_refresh = body["refresh_token"]

    post "/api/v1/oauth/token", params: {
      grant_type: "refresh_token", refresh_token: old_refresh,
      client_id: @client.client_id, client_secret: @secret
    }
    assert_response :success
    assert_not_equal old_access, json_response["access_token"]
    assert_not_equal old_refresh, json_response["refresh_token"]
    assert_not OauthAccessToken.find_by_token(old_access).active?
    assert_not OauthRefreshToken.find_by_token(old_refresh).active?
  end

  test "refresh does not extend the family's expiry" do
    # A stolen refresh token must not be renewable into a permanent session:
    # the chain still dies 30 days after the user consented.
    body = complete_flow
    original_expiry = OauthRefreshToken.find_by_token(body["refresh_token"]).expires_at

    post "/api/v1/oauth/token", params: {
      grant_type: "refresh_token", refresh_token: body["refresh_token"],
      client_id: @client.client_id, client_secret: @secret
    }
    new_expiry = OauthRefreshToken.find_by_token(json_response["refresh_token"]).expires_at
    assert_in_delta original_expiry.to_f, new_expiry.to_f, 1.0
  end

  test "reusing a rotated refresh token burns the whole family" do
    body = complete_flow
    first_refresh = body["refresh_token"]

    post "/api/v1/oauth/token", params: {
      grant_type: "refresh_token", refresh_token: first_refresh,
      client_id: @client.client_id, client_secret: @secret
    }
    second = json_response

    # The attacker replays the token the legitimate client already spent.
    post "/api/v1/oauth/token", params: {
      grant_type: "refresh_token", refresh_token: first_refresh,
      client_id: @client.client_id, client_secret: @secret
    }
    assert_response :bad_request
    assert_equal "invalid_grant", json_response["error"]

    # Everything descended from that authorization is dead, including the
    # tokens the legitimate client is holding right now.
    assert_not OauthRefreshToken.find_by_token(second["refresh_token"]).active?
    assert_not OauthAccessToken.find_by_token(second["access_token"]).active?
  end

  test "refresh can narrow the scope but never widen it" do
    body = complete_flow(scope: "openid profile")

    post "/api/v1/oauth/token", params: {
      grant_type: "refresh_token", refresh_token: body["refresh_token"],
      client_id: @client.client_id, client_secret: @secret, scope: "openid"
    }
    assert_response :success
    assert_equal "openid", json_response["scope"]
    narrowed = json_response

    # And having narrowed, it cannot climb back up.
    post "/api/v1/oauth/token", params: {
      grant_type: "refresh_token", refresh_token: narrowed["refresh_token"],
      client_id: @client.client_id, client_secret: @secret, scope: "openid profile"
    }
    assert_response :bad_request
    assert_equal "invalid_scope", json_response["error"]
  end

  test "refresh rejects a token belonging to another client" do
    body = complete_flow
    other_app, other_secret = create_oauth_application

    post "/api/v1/oauth/token", params: {
      grant_type: "refresh_token", refresh_token: body["refresh_token"],
      client_id: other_app.client_id, client_secret: other_secret
    }
    assert_response :bad_request
    assert_equal "invalid_grant", json_response["error"]
  end

  test "an unsupported grant_type is rejected" do
    post "/api/v1/oauth/token", params: { grant_type: "password", client_id: @client.client_id }
    assert_response :bad_request
    assert_equal "unsupported_grant_type", json_response["error"]
  end

  # --- userinfo ------------------------------------------------------------

  test "userinfo returns only the granted scopes' claims" do
    @user.update!(nickname: "Nick", bio: "hi", eth: "0xabc")
    body = complete_flow(scope: "openid profile")

    get "/api/v1/oauth/userinfo", headers: { "Authorization" => "Bearer #{body['access_token']}" }
    assert_response :success
    assert_equal @user.id, json_response["sub"]
    assert_equal @user.name, json_response["preferred_username"]
    assert_equal "hi", json_response["bio"]
    # email and wallet were not granted.
    assert_not json_response.key?("email")
    assert_not json_response.key?("wallet_address")
  end

  test "userinfo includes email only with the email scope" do
    body = complete_flow(scope: "openid email")
    get "/api/v1/oauth/userinfo", headers: { "Authorization" => "Bearer #{body['access_token']}" }
    assert_equal @user.email, json_response["email"]
    assert_equal true, json_response["email_verified"]
    assert_not json_response.key?("preferred_username")
  end

  test "userinfo returns the user's own groups for groups:read" do
    @client.update!(allowed_scopes: %w[openid groups:read])
    group = create_group(owner: @user)
    body = complete_flow(scope: "openid groups:read")

    get "/api/v1/oauth/userinfo", headers: { "Authorization" => "Bearer #{body['access_token']}" }
    assert_response :success
    assert_equal [ group.id ], json_response["groups"].map { |g| g["id"] }
    assert_equal "owner", json_response["groups"].first["role"]
  end

  test "token and userinfo responses forbid caching" do
    # RFC 6749 §5.1 makes this a MUST: without it a proxy or a browser is
    # entitled to keep a copy of somebody's access token.
    body = complete_flow
    assert_equal "no-store", response.headers["Cache-Control"]

    get "/api/v1/oauth/userinfo", headers: { "Authorization" => "Bearer #{body['access_token']}" }
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "userinfo answers on POST as well as GET" do
    # OIDC Core §5.3.1 requires both verbs.
    body = complete_flow
    post "/api/v1/oauth/userinfo", headers: { "Authorization" => "Bearer #{body['access_token']}" }
    assert_response :success
    assert_equal @user.id, json_response["sub"]
  end

  test "a missing bearer token gets a WWW-Authenticate challenge" do
    get "/api/v1/oauth/userinfo"
    assert_response :unauthorized
    assert_equal "Bearer", response.headers["WWW-Authenticate"]
  end

  test "userinfo rejects a sola session JWT" do
    # An OAuth access token and a sola session token are different credentials
    # and must not be interchangeable in either direction.
    get "/api/v1/oauth/userinfo", headers: auth_headers(@user)
    assert_response :unauthorized
    assert_equal "invalid_token", json_response["error"]
  end

  test "userinfo rejects an expired token" do
    body = complete_flow
    OauthAccessToken.find_by_token(body["access_token"]).update!(expires_at: 1.second.ago)
    get "/api/v1/oauth/userinfo", headers: { "Authorization" => "Bearer #{body['access_token']}" }
    assert_response :unauthorized
  end

  test "userinfo rejects a token whose application has been disabled" do
    body = complete_flow
    @client.disable!
    get "/api/v1/oauth/userinfo", headers: { "Authorization" => "Bearer #{body['access_token']}" }
    assert_response :unauthorized
  end

  test "an OAuth access token cannot be used against the rest of the API" do
    body = complete_flow
    get "/api/v1/oauth/grants", headers: { "Authorization" => "Bearer #{body['access_token']}" }
    assert_response :unauthorized
  end

  # --- revoke --------------------------------------------------------------

  test "revoke kills an access token" do
    body = complete_flow
    post "/api/v1/oauth/revoke", params: {
      token: body["access_token"], client_id: @client.client_id, client_secret: @secret
    }
    assert_response :success
    assert_not OauthAccessToken.find_by_token(body["access_token"]).active?
  end

  test "revoking a refresh token burns the family" do
    body = complete_flow
    post "/api/v1/oauth/revoke", params: {
      token: body["refresh_token"], client_id: @client.client_id, client_secret: @secret
    }
    assert_response :success
    assert_not OauthRefreshToken.find_by_token(body["refresh_token"]).active?
    assert_not OauthAccessToken.find_by_token(body["access_token"]).active?
  end

  test "revoke will not touch another client's token" do
    body = complete_flow
    other_app, other_secret = create_oauth_application

    post "/api/v1/oauth/revoke", params: {
      token: body["access_token"], client_id: other_app.client_id, client_secret: other_secret
    }
    # RFC 7009: unknown token is still a 200 — anything else makes this a
    # token-validity oracle for any registered client.
    assert_response :success
    assert OauthAccessToken.find_by_token(body["access_token"]).active?
  end

  # --- discovery -----------------------------------------------------------

  test "discovery document advertises the endpoints" do
    get "/.well-known/openid-configuration"
    assert_response :success
    assert_equal OauthConfig.issuer, json_response["issuer"]
    assert_equal "#{OauthConfig.issuer}/oauth/authorize", json_response["authorization_endpoint"]
    assert_equal "#{OauthConfig.issuer}/api/v1/oauth/token", json_response["token_endpoint"]
    assert_equal [ "S256" ], json_response["code_challenge_methods_supported"]
    assert_equal OauthApplication::VALID_SCOPES, json_response["scopes_supported"]
  end

  test "jwks exposes the public key" do
    with_oauth_signing_key do
      get "/.well-known/jwks.json"
      assert_response :success
      key = json_response["keys"].first
      assert_equal "RSA", key["kty"]
      assert_equal "RS256", key["alg"]
      assert_equal OauthConfig.key_id, key["kid"]
      assert key["n"].present?
    end
  end

  test "jwks answers with a key even when none is configured outside production" do
    get "/.well-known/jwks.json"
    assert_response :success
    assert_equal 1, json_response["keys"].size
  end

  test "the root authorize endpoint redirects the browser to the consent page" do
    get "/oauth/authorize", params: authorize_params
    assert_response :found
    assert response.headers["Location"].start_with?(OauthConfig.consent_url)
    assert_includes response.headers["Location"], "client_id=#{@client.client_id}"
  end
end
