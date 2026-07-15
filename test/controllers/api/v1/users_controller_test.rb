require "test_helper"

class Api::V1::UsersControllerTest < ActionDispatch::IntegrationTest
  test "show 'me' returns the current user" do
    user = create_user
    get "/api/v1/users/me", headers: auth_headers(user)
    assert_response :success
    assert_equal user.id, json_response["id"]
  end

  test "show by id returns any user" do
    user = create_user
    other = create_user
    get "/api/v1/users/#{other.id}", headers: auth_headers(user)
    assert_response :success
    assert_equal other.id, json_response["id"]
  end

  test "show 404s for an unknown id" do
    user = create_user
    get "/api/v1/users/does-not-exist", headers: auth_headers(user)
    assert_response :not_found
  end

  test "show requires authentication" do
    get "/api/v1/users/me"
    assert_response :unauthorized
  end

  test "update changes the current user's name" do
    user = create_user
    patch "/api/v1/users/#{user.id}", params: { user: { name: "New Name" } }, headers: auth_headers(user)
    assert_response :success
    assert_equal "New Name", user.reload.name
  end

  test "update ignores unpermitted params like email" do
    user = create_user
    original_email = user.email
    patch "/api/v1/users/#{user.id}", params: { user: { name: "New Name", email: "hacked@test.com" } }, headers: auth_headers(user)
    assert_response :success
    assert_equal original_email, user.reload.email
  end

  test "update rejects a blank name" do
    user = create_user
    patch "/api/v1/users/#{user.id}", params: { user: { name: "" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end
end
