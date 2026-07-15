require "test_helper"

class Api::V1::GroupsControllerTest < ActionDispatch::IntegrationTest
  test "create makes the creator the owner" do
    user = create_user
    assert_difference "Group.count", 1 do
      post "/api/v1/groups", params: { group: { name: "My Group" } }, headers: auth_headers(user)
    end
    assert_response :created
    group = Group.find(json_response["id"])
    assert_equal "owner", group.memberships.find_by(user: user).role
  end

  test "create requires a name" do
    user = create_user
    post "/api/v1/groups", params: { group: { name: "" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "index lists only the current user's groups" do
    user = create_user
    mine = create_group(owner: user)
    create_group # someone else's

    get "/api/v1/groups", headers: auth_headers(user)
    assert_response :success
    ids = json_response["data"].map { |g| g["id"] }
    assert_includes ids, mine.id
    assert_equal 1, ids.size
  end

  test "show works for any authenticated user" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)

    get "/api/v1/groups/#{group.id}", headers: auth_headers(outsider)
    assert_response :success
  end

  test "update requires group admin/owner" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)

    patch "/api/v1/groups/#{group.id}", params: { group: { name: "Renamed" } }, headers: auth_headers(outsider)
    assert_response :forbidden

    patch "/api/v1/groups/#{group.id}", params: { group: { name: "Renamed" } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "Renamed", group.reload.name
  end

  test "destroy requires group admin/owner" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)

    delete "/api/v1/groups/#{group.id}", headers: auth_headers(outsider)
    assert_response :forbidden

    delete "/api/v1/groups/#{group.id}", headers: auth_headers(owner)
    assert_response :no_content
  end
end
