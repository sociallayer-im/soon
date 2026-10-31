require "test_helper"

class Api::V1::FollowsControllerTest < ActionDispatch::IntegrationTest
  test "create follows a user and returns the id the client stores" do
    follower = create_user
    target = create_user(nickname: "小林")

    post "/api/v1/follows",
      params: { target_type: "User", target_id: target.id },
      headers: auth_headers(follower), as: :json

    assert_response :created
    body = json_response
    assert body["id"].present?
    assert_equal target.id, body["target_id"]
    assert_equal "User", body["target_type"]
    assert_equal "active", body["status"]
    assert_equal target.id, body.dig("target", "id")
    assert_equal "小林", body.dig("target", "nickname")
    assert_nil body.dig("target", "email")
    assert_nil body.dig("user", "email")
  end

  test "create follows a group and a repeated follow returns the same row" do
    follower = create_user
    group = create_group(owner: create_user)

    post "/api/v1/follows",
      params: { target_type: "Group", target_id: group.id },
      headers: auth_headers(follower), as: :json
    assert_response :created
    first_id = json_response["id"]
    assert_equal group.name, json_response.dig("target", "name")

    post "/api/v1/follows",
      params: { target_type: "Group", target_id: group.id },
      headers: auth_headers(follower), as: :json
    assert_response :ok
    assert_equal first_id, json_response["id"]
    assert_equal 1, Follow.where(user: follower, target: group).count
  end

  test "create accepts a username and refuses a self follow" do
    user = create_user
    other = create_user

    post "/api/v1/follows",
      params: { target_type: "User", target_id: other.name },
      headers: auth_headers(user), as: :json
    assert_response :created
    assert_equal other.id, json_response["target_id"]

    post "/api/v1/follows",
      params: { target_type: "User", target_id: user.id },
      headers: auth_headers(user), as: :json
    assert_response :unprocessable_entity
    assert_equal 0, Follow.where(user: user, target: user).count
  end

  test "create requires authentication and a real target" do
    user = create_user

    post "/api/v1/follows", params: { target_type: "User", target_id: user.id }, as: :json
    assert_response :unauthorized

    post "/api/v1/follows",
      params: { target_type: "Event", target_id: user.id },
      headers: auth_headers(user), as: :json
    assert_response :unprocessable_entity

    post "/api/v1/follows",
      params: { target_type: "User", target_id: "missing-person" },
      headers: auth_headers(user), as: :json
    assert_response :not_found
  end

  test "index lists one user's follows with profiles and pagination" do
    follower = create_user
    older_user = create_user
    newer_group = create_group(owner: create_user)
    outsider = create_user
    older = create_follow(user: follower, target: older_user)
    older.update_column(:created_at, 2.days.ago)
    newer = create_follow(user: follower, target: newer_group)
    create_follow(user: outsider, target: older_user)

    get "/api/v1/follows", params: { user_id: follower.id, include: "profiles", limit: 1, page: 1 }
    assert_response :success
    assert_equal [ newer.id ], json_response["data"].map { |row| row["id"] }
    assert_equal newer_group.id, json_response["data"].first.dig("target", "id")
    assert_equal 2, json_response["meta"]["total"]
    assert_equal 2, json_response["meta"]["next_page"]

    get "/api/v1/follows", params: { user_id: follower.name, include: "profiles", limit: 1, page: 2 }
    assert_response :success
    assert_equal [ older.id ], json_response["data"].map { |row| row["id"] }
    assert_nil json_response["meta"]["next_page"]
  end

  test "index without a subject is the signed-in user's follows" do
    user = create_user
    other = create_user
    target = create_user
    mine = create_follow(user: user, target: target)
    create_follow(user: other, target: target)

    get "/api/v1/follows", params: { include: "profiles" }
    assert_response :unauthorized

    get "/api/v1/follows", params: { include: "profiles" }, headers: auth_headers(user)
    assert_response :success
    assert_equal [ mine.id ], json_response["data"].map { |row| row["id"] }
    assert_equal "active", json_response["data"].first["status"]
  end

  test "followers direction returns the follower profile and not their email" do
    target = create_user
    follower = create_user(nickname: "小林")
    create_follow(user: follower, target: target)
    create_follow(user: create_user, target: create_group(owner: target))

    get "/api/v1/follows", params: {
      direction: "followers", target_id: target.id, target_type: "User", include: "profiles"
    }
    assert_response :success
    row = json_response["data"].first
    assert_equal follower.id, row.dig("user", "id")
    assert_equal "小林", row.dig("user", "nickname")
    assert_nil row.dig("user", "email")
    assert_equal 1, json_response["meta"]["total"]
  end

  test "destroy removes only the caller's follow" do
    user = create_user
    other = create_user
    follow = create_follow(user: user, target: other)

    delete "/api/v1/follows/#{follow.id}"
    assert_response :unauthorized
    assert Follow.exists?(follow.id)

    delete "/api/v1/follows/#{follow.id}", headers: auth_headers(other)
    assert_response :forbidden
    assert Follow.exists?(follow.id)

    delete "/api/v1/follows/#{follow.id}", headers: auth_headers(user)
    assert_response :success
    assert_equal "ok", json_response["result"]
    assert_not Follow.exists?(follow.id)
  end
  test "visible user relationship batch is filtered and profile counts persist through unfollow" do
    user = create_user
    target = create_user
    other = create_user
    follow = create_follow(user: user, target: target)
    create_follow(user: user, target: other)
    create_follow(user: other, target: target, status: "pending")
    get "/api/v1/follows", params: {target_ids: target.id, include: "", limit: 100}, headers: auth_headers(user)
    assert_response :ok
    assert_equal [follow.id], json_response["data"].map { |row| row["id"] }
    get "/api/v1/users/#{target.id}", headers: auth_headers(user)
    assert_equal 1, json_response["followers_count"]
    delete "/api/v1/follows/#{follow.id}", headers: auth_headers(user)
    assert_response :ok
    get "/api/v1/follows", params: {target_ids: target.id}, headers: auth_headers(user)
    assert_empty json_response["data"]
    get "/api/v1/users/#{target.id}", headers: auth_headers(user)
    assert_equal 0, json_response["followers_count"]
  end

end
