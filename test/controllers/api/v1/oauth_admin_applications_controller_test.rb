require "test_helper"

class Api::V1::OauthAdminApplicationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = create_user(admin: true)
    @client, = create_oauth_application
  end

  # semi's equivalent endpoint had no authentication at all, so anyone could
  # enumerate every registered application and its owner.
  test "a non-admin cannot list applications" do
    get "/api/v1/oauth/admin/applications", headers: auth_headers(create_user)
    assert_response :forbidden
  end

  test "an anonymous caller cannot list applications" do
    get "/api/v1/oauth/admin/applications"
    assert_response :unauthorized
  end

  test "an admin lists every application with owner detail" do
    get "/api/v1/oauth/admin/applications", headers: auth_headers(@admin)
    assert_response :success
    row = json_response["data"].find { |a| a["id"] == @client.id }
    assert row
    assert_equal @client.owner_id, row["owner_id"]
    assert_equal 0, row["grant_count"]
  end

  test "an admin can search by name or client_id" do
    get "/api/v1/oauth/admin/applications", params: { q: @client.client_id }, headers: auth_headers(@admin)
    assert_response :success
    assert_equal [ @client.id ], json_response["data"].map { |a| a["id"] }
  end

  test "review marks and unmarks an application" do
    post "/api/v1/oauth/admin/applications/#{@client.id}/review", headers: auth_headers(@admin)
    assert_response :success
    assert @client.reload.reviewed_at.present?

    post "/api/v1/oauth/admin/applications/#{@client.id}/review", params: { reviewed: false },
         headers: auth_headers(@admin)
    assert_nil @client.reload.reviewed_at
  end

  test "disable stops the application and burns its live tokens" do
    # With no registration review, this is the platform's only lever against an
    # app already in the wild — blocking new authorizations alone would leave
    # every token it already holds working.
    user = create_user
    access = OauthAccessToken.issue(user: user, application: @client, scopes: %w[openid])
    refresh = OauthRefreshToken.issue(user: user, application: @client, access_token: access)

    post "/api/v1/oauth/admin/applications/#{@client.id}/disable", headers: auth_headers(@admin)
    assert_response :success
    assert_equal "disabled", @client.reload.status
    assert_not access.reload.active?
    assert_not refresh.reload.active?
  end

  test "a non-admin cannot disable an application" do
    post "/api/v1/oauth/admin/applications/#{@client.id}/disable", headers: auth_headers(create_user)
    assert_response :forbidden
    assert_equal "active", @client.reload.status
  end
end
