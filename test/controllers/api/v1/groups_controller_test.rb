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

  test "create sets memberships_count to 1 via the owner membership" do
    user = create_user
    post "/api/v1/groups", params: { group: { name: "Counted" } }, headers: auth_headers(user)
    assert_response :created
    assert_equal 1, Group.find(json_response["id"]).memberships_count
  end

  test "update persists timezone" do
    owner = create_user
    group = create_group(owner: owner)

    patch "/api/v1/groups/#{group.id}", params: { group: { timezone: "Europe/Zurich" } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "Europe/Zurich", group.reload.timezone
  end

  test "a parent-group manager can manage a child group" do
    owner = create_user
    parent = create_group(owner: owner)
    child = create_group(name: "child-group", parent_id: parent.id)

    patch "/api/v1/groups/#{child.id}", params: { group: { name: "child-renamed" } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "child-renamed", child.reload.name
  end

  test "create under an unmanaged parent is forbidden" do
    stranger = create_user
    other_owner = create_user
    parent = create_group(owner: other_owner)

    post "/api/v1/groups", params: { group: { name: "sneaky", parent_id: parent.id } }, headers: auth_headers(stranger)
    assert_response :forbidden
    assert_not Group.exists?(name: "sneaky")
  end
end
