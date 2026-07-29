require "test_helper"

class Api::V1::MarkersControllerTest < ActionDispatch::IntegrationTest
  test "index lists markers scoped to the current user's groups" do
    user = create_user
    owner = create_user
    my_group = create_group(owner: user)
    other_group = create_group(owner: owner)
    place = create_place
    mine = create_marker(group: my_group, place: place, owner: user)
    create_marker(group: other_group, place: place, owner: owner)

    get "/api/v1/markers", headers: auth_headers(user)
    assert_response :success
    ids = json_response["data"].map { |m| m["id"] }
    assert_includes ids, mine.id
    assert_equal 1, ids.size
  end

  test "index is public with a group filter but rejects an anonymous firehose" do
    get "/api/v1/markers"
    assert_response :unprocessable_entity
  end

  test "index excludes a removed marker but includes one with no status set" do
    user = create_user
    group = create_group(owner: user)
    place = create_place
    active = create_marker(group: group, place: place, owner: user, status: nil)
    removed = create_marker(group: group, place: place, owner: user, status: "removed")

    get "/api/v1/markers", params: { group_id: group.id }
    assert_response :success
    ids = json_response["data"].map { |m| m["id"] }
    assert_includes ids, active.id
    assert_not_includes ids, removed.id
  end

  test "show returns a marker with its associations" do
    user = create_user
    group = create_group(owner: user)
    place = create_place
    marker = create_marker(group: group, place: place, owner: user, title: "My Marker")

    get "/api/v1/markers/#{marker.id}", headers: auth_headers(user)
    assert_response :success
    assert_equal "My Marker", json_response["title"]
    assert_equal place.id, json_response["place"]["id"]
    assert_equal group.id, json_response["group"]["id"]
    assert_equal user.id, json_response["owner"]["id"]
  end

  test "show 404s for an unknown id" do
    user = create_user
    get "/api/v1/markers/does-not-exist", headers: auth_headers(user)
    assert_response :not_found
  end

  test "create makes the current user the owner" do
    user = create_user
    group = create_group(owner: user)
    place = create_place

    assert_difference "Marker.count", 1 do
      post "/api/v1/markers", params: { marker: { title: "New Marker", place_id: place.id, group_id: group.id } },
        headers: auth_headers(user)
    end
    assert_response :created
    assert_equal user.id, Marker.last.owner_id
  end

  test "create requires title/place_id/group_id" do
    user = create_user
    post "/api/v1/markers", params: { marker: { title: "" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  # MarkerPolicy is enforced: create needs group membership; update/destroy
  # need the owner or a group manager.
  test "create rejects a non-member creating a marker in someone else's group" do
    outsider = create_user
    owner = create_user
    group = create_group(owner: owner)
    place = create_place

    post "/api/v1/markers", params: { marker: { title: "Intruder Marker", place_id: place.id, group_id: group.id } },
      headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "update rejects a non-owner non-manager" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    place = create_place
    marker = create_marker(group: group, place: place, owner: owner)

    patch "/api/v1/markers/#{marker.id}", params: { marker: { title: "Hijacked" } }, headers: auth_headers(outsider)
    assert_response :forbidden
    assert_not_equal "Hijacked", marker.reload.title
  end

  test "update persists valid changes" do
    user = create_user
    group = create_group(owner: user)
    place = create_place
    marker = create_marker(group: group, place: place, owner: user)

    patch "/api/v1/markers/#{marker.id}", params: { marker: { title: "Updated Title", about: "New about" } },
      headers: auth_headers(user)
    assert_response :success
    assert_equal "Updated Title", marker.reload.title
    assert_equal "New about", marker.about
  end

  test "update rejects a blank title" do
    user = create_user
    group = create_group(owner: user)
    place = create_place
    marker = create_marker(group: group, place: place, owner: user)

    patch "/api/v1/markers/#{marker.id}", params: { marker: { title: "" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "destroy rejects a non-owner non-manager" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    place = create_place
    marker = create_marker(group: group, place: place, owner: owner)

    delete "/api/v1/markers/#{marker.id}", headers: auth_headers(outsider)
    assert_response :forbidden
    assert Marker.exists?(marker.id)
  end

  test "destroy 404s for an unknown id" do
    user = create_user
    delete "/api/v1/markers/does-not-exist", headers: auth_headers(user)
    assert_response :not_found
  end
end
