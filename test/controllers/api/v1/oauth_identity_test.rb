require "test_helper"

class Api::V1::OauthIdentityTest < ActionDispatch::IntegrationTest
  def setup
    @user = create_user(nickname: "联网用户", phone: "+8613800000000")
    @client, @secret = create_oauth_application(allowed_scopes: %w[openid profile groups:read])
    @token = OauthAccessToken.issue(user: @user, application: @client, scopes: %w[openid profile groups:read])
  end

  def request_identity(token = @token.plaintext_token, **params)
    get "/api/v1/oauth/identity", params: params, headers: {"Authorization" => "Bearer #{token}"}
  end

  test "identity is scoped minimal stable and not cacheable" do
    request_identity
    assert_response :success
    assert_equal OauthConfig.issuer, json_response["issuer"]
    assert_equal @user.id, json_response["subject"]
    assert_equal @user.name, json_response["username"]
    assert_equal @token.expires_at.to_i, json_response["expires_at"]
    assert_equal %w[avatar_url expires_at issuer nickname scope subject username], json_response.keys.sort
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "requires OAuth token rather than normal session JWT" do
    get "/api/v1/oauth/identity"
    assert_response :unauthorized
    request_identity(JwtService.encode({user_id: @user.id}))
    assert_response :unauthorized
    request_identity("unrecognized")
    assert_response :unauthorized
  end

  test "expired revoked disabled client and disabled account fail closed" do
    @token.update!(expires_at: 1.second.ago)
    request_identity
    assert_response :unauthorized
    @token.update!(expires_at: 1.hour.from_now, revoked_at: Time.current)
    request_identity
    assert_response :unauthorized
    @token.update!(revoked_at: nil)
    @client.update!(status: "disabled")
    request_identity
    assert_response :unauthorized
    @client.update!(status: "active")
    @user.update!(active: false)
    request_identity
    assert_response :unauthorized
    get "/api/v1/oauth/userinfo", headers: {"Authorization" => "Bearer #{@token.plaintext_token}"}
    assert_response :unauthorized
  end

  test "openid is mandatory profile and membership scopes cannot be widened" do
    @token.update!(scopes: ["profile"])
    request_identity
    assert_response :forbidden
    @token.update!(scopes: ["openid"])
    request_identity
    assert_response :success
    assert_not json_response.key?("username")
    request_identity(group_id: "some-group")
    assert_response :forbidden
    assert_equal "insufficient_scope", json_response["error"]
  end

  test "owner manager and member are reported only while current and approved" do
    group = create_group(review_status: "approved")
    membership = create_membership(user: @user, group: group)
    %w[owner manager member].each do |role|
      membership.update!(role: role, expires_at: 1.hour.from_now)
      request_identity(group_id: group.id)
      assert_response :success
      assert_equal true, json_response.dig("group", "member")
      assert_equal role, json_response.dig("group", "role")
      assert_equal membership.expires_at.to_i, json_response.dig("group", "expires_at")
    end
    membership.update!(expires_at: 1.second.ago)
    request_identity(group_id: group.id)
    assert_equal false, json_response.dig("group", "member")
    membership.update!(expires_at: nil, active: false)
    request_identity(group_id: group.id)
    assert_equal false, json_response.dig("group", "member")
    membership.update!(active: true)
    group.update!(active: false)
    request_identity(group_id: group.id)
    assert_equal false, json_response.dig("group", "member")
    group.update!(active: true, review_status: "pending")
    request_identity(group_id: group.id)
    assert_equal false, json_response.dig("group", "member")
  end

  test "does not borrow another users membership or disclose missing groups" do
    group = create_group(owner: create_user, review_status: "approved")
    [group.id, "missing-group"].each do |id|
      request_identity(group_id: id)
      assert_response :success
      assert_equal({"id" => id, "member" => false, "role" => nil, "expires_at" => nil}, json_response["group"])
    end
    request_identity(group_id: [group.id])
    assert_response :bad_request
  end

  test "target lookup does not use truncated userinfo lists" do
    # UserInfo list pagination is irrelevant: the lookup uses a group predicate.
    group = create_group(review_status: "approved")
    create_membership(user: @user, group: group)
    OauthClaims.stub(:new, ->(*) { raise "must not load UserInfo lists" }) do
      request_identity(group_id: group.id)
      assert_equal true, json_response.dig("group", "member")
    end
  end
  test "authorization code PKCE exchange supplies identity and revocation removes access" do
    verifier = "w" * 43
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    redirect = @client.redirect_uris.first
    post "/api/v1/oauth/authorize", params: {
      client_id: @client.client_id, redirect_uri: redirect, response_type: "code",
      scope: "openid profile groups:read", code_challenge: challenge,
      code_challenge_method: "S256", decision: "allow"
    }, headers: auth_headers(@user)
    assert_response :success
    code = json_response.fetch("code")
    with_oauth_signing_key do
      post "/api/v1/oauth/token", params: {
        grant_type: "authorization_code", client_id: @client.client_id,
        client_secret: @secret, redirect_uri: redirect, code: code, code_verifier: verifier
      }
    end
    assert_response :success
    token = json_response.fetch("access_token")
    request_identity(token)
    assert_response :success
    assert_equal @user.id, json_response["subject"]
    post "/api/v1/oauth/revoke", params: {
      client_id: @client.client_id, client_secret: @secret, token: token
    }
    assert_response :success
    request_identity(token)
    assert_response :unauthorized
  end

end
