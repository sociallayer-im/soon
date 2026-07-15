require "test_helper"

class Api::V1::EventsControllerTest < ActionDispatch::IntegrationTest
  test "index lists only events in the current user's groups" do
    owner = create_user
    group = create_group(owner: owner)
    mine = create_event(group: group, owner: owner)
    create_event(group: create_group, owner: create_user) # someone else's

    get "/api/v1/events", headers: auth_headers(owner)
    assert_response :success
    ids = json_response["data"].map { |e| e["id"] }
    assert_includes ids, mine.id
    assert_equal 1, ids.size
  end

  test "show works for any authenticated user" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)

    get "/api/v1/events/#{event.id}", headers: auth_headers(outsider)
    assert_response :success
    assert_equal event.id, json_response["id"]
  end

  test "show 404s for an unknown id" do
    user = create_user
    get "/api/v1/events/does-not-exist", headers: auth_headers(user)
    assert_response :not_found
  end

  test "create requires group membership (EventPolicy#create? = group_member?)" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    place = create_place

    post "/api/v1/events", params: {
      event: { title: "Meetup", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour,
                group_id: group.id, place_id: place.id }
    }, headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "create succeeds for a group member" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    place = create_place

    assert_difference "Event.count", 1 do
      post "/api/v1/events", params: {
        event: { title: "Meetup", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour,
                  group_id: group.id, place_id: place.id }
      }, headers: auth_headers(member)
    end
    assert_response :created
    event = Event.find(json_response["id"])
    assert_equal member.id, event.owner_id
  end

  test "create validates presence of title/start_time/end_time" do
    owner = create_user
    group = create_group(owner: owner)

    post "/api/v1/events", params: {
      event: { title: "", group_id: group.id }
    }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
  end

  test "create validates end_time is after start_time" do
    owner = create_user
    group = create_group(owner: owner)

    post "/api/v1/events", params: {
      event: { title: "Bad Timing", start_time: 1.day.from_now, end_time: 1.day.from_now - 1.hour,
                group_id: group.id }
    }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match(/after start time/, json_response["error"])
  end

  test "update requires owner or group admin" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)

    patch "/api/v1/events/#{event.id}", params: { event: { title: "Renamed" } }, headers: auth_headers(outsider)
    assert_response :forbidden

    patch "/api/v1/events/#{event.id}", params: { event: { title: "Renamed" } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "Renamed", event.reload.title
  end

  test "update succeeds for a group admin who isn't the owner" do
    owner = create_user
    admin = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "admin")
    event = create_event(group: group, owner: owner)

    patch "/api/v1/events/#{event.id}", params: { event: { title: "Admin Renamed" } }, headers: auth_headers(admin)
    assert_response :success
    assert_equal "Admin Renamed", event.reload.title
  end

  test "destroy requires owner or group admin" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)

    delete "/api/v1/events/#{event.id}", headers: auth_headers(outsider)
    assert_response :forbidden

    delete "/api/v1/events/#{event.id}", headers: auth_headers(owner)
    assert_response :no_content
  end

  test "index/show require authentication" do
    get "/api/v1/events"
    assert_response :unauthorized
  end
end
