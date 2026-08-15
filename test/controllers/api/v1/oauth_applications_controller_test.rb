require "test_helper"

class Api::V1::OauthApplicationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = create_user
  end

  def valid_params(**overrides)
    { application: {
      name: "My Client",
      redirect_uris: [ "https://client.example.com/callback" ],
      allowed_scopes: %w[openid profile]
    }.merge(overrides) }
  end

  test "any signed-in user can register an application" do
    post "/api/v1/oauth/applications", params: valid_params, headers: auth_headers(@user)
    assert_response :created
    assert json_response["client_id"].start_with?("sola_")
    assert_equal "draft", json_response["status"]
    assert json_response["client_secret"].present?
  end

  test "the client secret is returned once and never again" do
    post "/api/v1/oauth/applications", params: valid_params, headers: auth_headers(@user)
    id = json_response["id"]
    secret = json_response["client_secret"]
    assert secret.present?

    get "/api/v1/oauth/applications/#{id}", headers: auth_headers(@user)
    assert_response :success
    assert_not json_response.key?("client_secret")

    get "/api/v1/oauth/applications", headers: auth_headers(@user)
    assert_not json_response.first.key?("client_secret")
  end

  test "rotate_secret issues a new secret and invalidates the old one" do
    app, old_secret = create_oauth_application(owner: @user)
    post "/api/v1/oauth/applications/#{app.id}/rotate_secret", headers: auth_headers(@user)
    assert_response :success
    new_secret = json_response["client_secret"]
    assert_not_equal old_secret, new_secret
    assert app.reload.authenticate_secret(new_secret)
    assert_not app.authenticate_secret(old_secret)
  end

  test "a public client is created without a secret" do
    post "/api/v1/oauth/applications", params: valid_params(confidential: false), headers: auth_headers(@user)
    assert_response :created
    assert_nil json_response["client_secret"]
    assert_equal false, json_response["confidential"]
  end

  test "rotate_secret is rejected for a public client" do
    app, = create_oauth_application(owner: @user, confidential: false)
    post "/api/v1/oauth/applications/#{app.id}/rotate_secret", headers: auth_headers(@user)
    assert_response :unprocessable_entity
  end

  test "an application name that impersonates the platform is rejected" do
    # The only defence against a phishing client, given registration is not
    # reviewed — see design/OAUTH_PROVIDER_PLAN.md §9.
    [ "Social Layer Login", "sola.day", "聚落登录", "Juluo" ].each do |name|
      post "/api/v1/oauth/applications", params: valid_params(name: name), headers: auth_headers(@user)
      assert_response :unprocessable_entity, "expected #{name.inspect} to be rejected"
    end
  end

  test "a name that merely contains the letters is not blocked" do
    # The reserved patterns are word-bounded: "Solana" and "Solar" impersonate
    # nothing, and rejecting them would be a support ticket, not a defence.
    [ "Solana Wallet", "Solar Punk Club" ].each do |name|
      post "/api/v1/oauth/applications", params: valid_params(name: name), headers: auth_headers(create_user)
      assert_response :created, "expected #{name.inspect} to be accepted"
    end
  end

  test "a platform admin may register a first-party name" do
    admin = create_user(admin: true)
    post "/api/v1/oauth/applications", params: valid_params(name: "Social Layer iOS"), headers: auth_headers(admin)
    assert_response :created
  end

  test "an http redirect_uri outside localhost is rejected" do
    post "/api/v1/oauth/applications",
         params: valid_params(redirect_uris: [ "http://client.example.com/cb" ]),
         headers: auth_headers(@user)
    assert_response :unprocessable_entity
  end

  test "an http localhost redirect_uri is allowed for development" do
    post "/api/v1/oauth/applications",
         params: valid_params(redirect_uris: [ "http://localhost:4000/callback" ]),
         headers: auth_headers(@user)
    assert_response :created
  end

  test "an unknown scope is rejected" do
    post "/api/v1/oauth/applications", params: valid_params(allowed_scopes: %w[openid admin:everything]),
         headers: auth_headers(@user)
    assert_response :unprocessable_entity
  end

  test "the per-owner application cap is enforced" do
    OauthApplication::MAX_PER_OWNER.times { create_oauth_application(owner: @user) }
    post "/api/v1/oauth/applications", params: valid_params, headers: auth_headers(@user)
    assert_response :unprocessable_entity
  end

  test "trusted cannot be set through the API" do
    # It skips the consent screen entirely; nothing self-service may grant it.
    post "/api/v1/oauth/applications", params: valid_params(trusted: true), headers: auth_headers(@user)
    assert_response :created
    assert_equal false, OauthApplication.find(json_response["id"]).trusted
  end

  test "index only lists the caller's own applications" do
    mine, = create_oauth_application(owner: @user)
    theirs, = create_oauth_application

    get "/api/v1/oauth/applications", headers: auth_headers(@user)
    assert_response :success
    ids = json_response.map { |a| a["id"] }
    assert_includes ids, mine.id
    assert_not_includes ids, theirs.id
  end

  test "another user's application cannot be read, updated or deleted" do
    app, = create_oauth_application

    get "/api/v1/oauth/applications/#{app.id}", headers: auth_headers(@user)
    assert_response :not_found
    patch "/api/v1/oauth/applications/#{app.id}", params: valid_params, headers: auth_headers(@user)
    assert_response :not_found
    delete "/api/v1/oauth/applications/#{app.id}", headers: auth_headers(@user)
    assert_response :not_found
  end

  test "the owner can self-activate without review" do
    app, = create_oauth_application(owner: @user, status: "draft")
    patch "/api/v1/oauth/applications/#{app.id}",
          params: { application: { status: "active" } }, headers: auth_headers(@user)
    assert_response :success
    assert_equal "active", app.reload.status
  end

  test "deleting an application ends the sessions it holds" do
    app, = create_oauth_application(owner: @user)
    token = OauthAccessToken.issue(user: @user, application: app, scopes: %w[openid])

    delete "/api/v1/oauth/applications/#{app.id}", headers: auth_headers(@user)
    assert_response :success
    assert_nil OauthAccessToken.find_by(id: token.id)
  end

  test "registering under a group requires managing that group" do
    group = create_group(owner: create_user)
    post "/api/v1/oauth/applications", params: valid_params.merge(group_id: group.id),
         headers: auth_headers(@user)
    assert_response :forbidden
  end

  test "a group manager may register under the group" do
    group = create_group(owner: @user)
    post "/api/v1/oauth/applications", params: valid_params.merge(group_id: group.id),
         headers: auth_headers(@user)
    assert_response :created
    assert_equal "group", json_response["owner_type"]
    assert_equal group.name, json_response["owner_handle"]
  end

  test "the endpoints require authentication" do
    get "/api/v1/oauth/applications"
    assert_response :unauthorized
  end
end
