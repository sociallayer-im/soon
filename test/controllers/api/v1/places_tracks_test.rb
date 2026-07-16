require "test_helper"

# Places find-or-create/search and tracks CRUD — the location + schedule-track
# management endpoints the frontend event/venue editors depend on.
class PlacesTracksTest < ActionDispatch::IntegrationTest
  # --- places ---

  test "place create is find-or-create by name" do
    user = create_user

    post "/api/v1/places", params: { place: { name: "Shibuya Hall", address: "Tokyo",
      latitude: 35.66, longitude: 139.7, data: { google_place_id: "abc" } } },
      headers: auth_headers(user)
    assert_response :created
    id = json_response["id"]
    assert_equal({ "google_place_id" => "abc" }, json_response["data"])

    # Same name → the existing place, not a duplicate or an error.
    assert_no_difference -> { Place.count } do
      post "/api/v1/places", params: { place: { name: "Shibuya Hall" } }, headers: auth_headers(user)
    end
    assert_response :success
    assert_equal id, json_response["id"]
  end

  test "place accepts longitudes beyond 90 degrees" do
    place = create_place(latitude: 35.66, longitude: 139.7) # Tokyo
    assert place.persisted?
    assert_not Place.new(name: "x", longitude: 200).valid?
  end

  test "place search matches name and address" do
    user = create_user
    hit = create_place(name: "moon-cafe", address: "1 Luna St")
    create_place(name: "other-spot")

    get "/api/v1/places/search", params: { query: "moon" }, headers: auth_headers(user)
    assert_response :success
    assert_equal [hit.id], json_response.map { |p| p["id"] }

    get "/api/v1/places/search", params: { query: "luna" }, headers: auth_headers(user)
    assert_equal [hit.id], json_response.map { |p| p["id"] }
  end

  # --- tracks ---

  test "group manager can create a track with managers; name is generated" do
    owner = create_user
    manager = create_user
    group = create_group(owner: owner)
    create_membership(user: manager, group: group)

    post "/api/v1/tracks", params: { track: { group_id: group.id, title: "Main Stage",
      manager_ids: [manager.id] } }, headers: auth_headers(owner)
    assert_response :created
    assert_match(/main-stage/, json_response["name"])
    assert_equal [manager.id], json_response["track_roles"].map { |r| r["user"]["id"] }
    assert_equal ["admin"], json_response["track_roles"].map { |r| r["role"] }
  end

  test "non-manager cannot create or update a track" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group)
    track = create_track(group: group)

    post "/api/v1/tracks", params: { track: { group_id: group.id, title: "X" } },
      headers: auth_headers(member)
    assert_response :forbidden

    patch "/api/v1/tracks/#{track.id}", params: { track: { title: "Y" } },
      headers: auth_headers(member)
    assert_response :forbidden
  end

  test "update syncs manager roles and destroy nullifies events" do
    owner = create_user
    m1 = create_user
    m2 = create_user
    group = create_group(owner: owner)
    track = create_track(group: group)
    TrackRole.create!(track: track, user: m1, role: "admin")

    patch "/api/v1/tracks/#{track.id}", params: { track: { title: "New Title",
      manager_ids: [m2.id] } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "New Title", track.reload.title
    assert_equal [m2.id], track.track_roles.where(role: "admin").pluck(:user_id)

    event = create_event(group: group, owner: owner, track_id: track.id)
    delete "/api/v1/tracks/#{track.id}", headers: auth_headers(owner)
    assert_response :no_content
    assert_nil event.reload.track_id
  end

  test "track index is public and filters by group slug" do
    owner = create_user
    group = create_group(owner: owner)
    track = create_track(group: group)
    create_track(group: create_group)

    get "/api/v1/tracks", params: { group_id: group.name }
    assert_response :success
    assert_equal [track.id], json_response["data"].map { |t| t["id"] }
  end
end
