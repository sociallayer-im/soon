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
    patch "/api/v1/users/#{user.id}", params: { user: { name: "new_name" } }, headers: auth_headers(user)
    assert_response :success
    assert_equal "new_name", user.reload.name
  end

  test "update ignores unpermitted params like email" do
    user = create_user
    original_email = user.email
    patch "/api/v1/users/#{user.id}", params: { user: { name: "new_name", email: "hacked@test.com" } }, headers: auth_headers(user)
    assert_response :success
    assert_equal original_email, user.reload.email
  end

  test "update rejects a blank name" do
    user = create_user
    patch "/api/v1/users/#{user.id}", params: { user: { name: "" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "show reveals own email but hides other users' email" do
    user = create_user
    other = create_user

    get "/api/v1/users/me", headers: auth_headers(user)
    assert_response :success
    assert_equal user.email, json_response["email"]

    get "/api/v1/users/#{other.id}", headers: auth_headers(user)
    assert_response :success
    assert_not json_response.key?("email")
  end

  test "update rejects a name that is not a valid slug" do
    user = create_user
    patch "/api/v1/users/#{user.id}", params: { user: { name: "Not A Slug" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "update rejects a name already taken by another user" do
    taken = create_user(name: "taken_name")
    user = create_user
    patch "/api/v1/users/#{user.id}", params: { user: { name: "taken_name" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "name is the unique identifier — two users cannot share one" do
    create_user(name: "duplicate_name")
    assert_raises(ActiveRecord::RecordInvalid) { create_user(name: "duplicate_name") }
  end

  test "name must be a lowercase slug at creation time" do
    assert_raises(ActiveRecord::RecordInvalid) { create_user(name: "Has Spaces") }
    assert_raises(ActiveRecord::RecordInvalid) { create_user(name: "UPPER") }
  end

  test "a user is resolvable by name via the badge owner filter" do
    owner = create_user(name: "resolvable_user")
    bc = create_badge_class(creator: owner)
    badge = create_badge(badge_class: bc, creator: owner, owner: owner)

    get "/api/v1/badges", params: { owner_handle: "resolvable_user" }, headers: auth_headers(owner)
    assert_response :success
    assert_equal [badge.id], json_response["data"].map { |b| b["id"] }
  end

  test "groups lists a user's active memberships in active groups" do
    user = create_user
    active_group = create_group(owner: user)

    get "/api/v1/users/#{user.id}/groups"
    assert_response :success
    ids = json_response.map { |m| m["group"]["id"] }
    assert_equal [active_group.id], ids
  end

  test "groups excludes memberships in a deactivated (frozen) group" do
    user = create_user
    active_group = create_group(owner: user)
    frozen_group = create_group(owner: user, active: false)

    get "/api/v1/users/#{user.id}/groups"
    assert_response :success
    ids = json_response.map { |m| m["group"]["id"] }
    assert_equal [active_group.id], ids
    assert_not_includes ids, frozen_group.id
  end

  test "groups excludes an inactive membership" do
    user = create_user
    group = create_group
    create_membership(user: user, group: group, active: false)

    get "/api/v1/users/#{user.id}/groups"
    assert_response :success
    assert_empty json_response
  end

  test "groups does not require authentication" do
    user = create_user
    create_group(owner: user)

    get "/api/v1/users/#{user.id}/groups"
    assert_response :success
  end

  test "groups orders by when the group was created, not when the user joined it" do
    user = create_user
    older_group = create_group(created_at: 2.days.ago)
    newer_group = create_group(created_at: 1.day.ago)
    # join the newer group first, so a join-time sort would list them reversed
    create_membership(user: user, group: newer_group, created_at: 2.hours.ago)
    create_membership(user: user, group: older_group, created_at: 1.hour.ago)

    get "/api/v1/users/#{user.id}/groups"
    assert_response :success
    ids = json_response.map { |m| m["group"]["id"] }
    assert_equal [older_group.id, newer_group.id], ids
  end
end
