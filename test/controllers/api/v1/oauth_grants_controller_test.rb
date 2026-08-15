require "test_helper"

class Api::V1::OauthGrantsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = create_user
    @client, = create_oauth_application
  end

  test "index lists only the caller's own grants" do
    mine = OauthGrant.upsert_for(user: @user, application: @client, scopes: %w[openid profile])
    theirs = OauthGrant.upsert_for(user: create_user, application: @client, scopes: %w[openid])

    get "/api/v1/oauth/grants", headers: auth_headers(@user)
    assert_response :success
    ids = json_response.map { |g| g["id"] }
    assert_includes ids, mine.id
    assert_not_includes ids, theirs.id
    assert_equal @client.name, json_response.first["app_name"]
    assert_equal 2, json_response.first["scope_details"].size
  end

  test "revoking a grant also kills the tokens it produced" do
    grant = OauthGrant.upsert_for(user: @user, application: @client, scopes: %w[openid])
    access = OauthAccessToken.issue(user: @user, application: @client, scopes: %w[openid])
    refresh = OauthRefreshToken.issue(user: @user, application: @client, access_token: access)

    delete "/api/v1/oauth/grants/#{grant.id}", headers: auth_headers(@user)
    assert_response :success
    assert_nil OauthGrant.find_by(id: grant.id)
    assert_not access.reload.active?
    assert_not refresh.reload.active?
  end

  test "another user's grant cannot be revoked" do
    grant = OauthGrant.upsert_for(user: create_user, application: @client, scopes: %w[openid])
    delete "/api/v1/oauth/grants/#{grant.id}", headers: auth_headers(@user)
    assert_response :not_found
    assert OauthGrant.find_by(id: grant.id)
  end

  test "the endpoints require authentication" do
    get "/api/v1/oauth/grants"
    assert_response :unauthorized
  end
end
