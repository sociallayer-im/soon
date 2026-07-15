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

  test "index requires authentication" do
    get "/api/v1/markers"
    assert_response :unauthorized
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

  # KNOWN GAP (pre-existing, not introduced this session, out of scope to fix here):
  # MarkersController never calls `authorize`, even though app/policies/marker_policy.rb
  # defines create?/update?/destroy? rules (group_member?/owner?/group_admin?). Any
  # authenticated user can create a marker in ANY group, and update/destroy ANY marker
  # regardless of ownership or group membership. These tests document the actual
  # (unauthorized) behavior rather than the intended-per-policy behavior.
  test "create currently allows a non-member to create a marker in someone else's group (KNOWN GAP — MarkerPolicy is never invoked)" do
    outsider = create_user
    owner = create_user
    group = create_group(owner: owner)
    place = create_place

    post "/api/v1/markers", params: { marker: { title: "Intruder Marker", place_id: place.id, group_id: group.id } },
      headers: auth_headers(outsider)
    assert_response :created
  end

  test "update currently allows any authenticated user to update any marker (KNOWN GAP — MarkerPolicy is never invoked)" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    place = create_place
    marker = create_marker(group: group, place: place, owner: owner)

    patch "/api/v1/markers/#{marker.id}", params: { marker: { title: "Hijacked" } }, headers: auth_headers(outsider)
    assert_response :success
    assert_equal "Hijacked", marker.reload.title
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

  test "destroy currently allows any authenticated user to destroy any marker (KNOWN GAP — MarkerPolicy is never invoked)" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    place = create_place
    marker = create_marker(group: group, place: place, owner: owner)

    delete "/api/v1/markers/#{marker.id}", headers: auth_headers(outsider)
    assert_response :no_content
    assert_not Marker.exists?(marker.id)
  end

  test "destroy 404s for an unknown id" do
    user = create_user
    delete "/api/v1/markers/does-not-exist", headers: auth_headers(user)
    assert_response :not_found
  end
end
