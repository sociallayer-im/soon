require "test_helper"

class Api::V1::VenuesControllerTest < ActionDispatch::IntegrationTest
  test "index lists venues" do
    user = create_user
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)

    get "/api/v1/venues", headers: auth_headers(user)
    assert_response :success
    ids = json_response["data"].map { |v| v["id"] }
    assert_includes ids, venue.id
  end

  test "index requires authentication" do
    get "/api/v1/venues"
    assert_response :unauthorized
  end

  test "index with group_id only returns that group's venues" do
    user = create_user
    owner = create_user
    group = create_group(owner: owner)
    other_group = create_group(owner: owner)
    mine = create_venue(group: group, owner: owner)
    create_venue(group: other_group, owner: owner)

    get "/api/v1/venues", params: { group_id: group.id }, headers: auth_headers(user)
    assert_response :success
    assert_equal [mine.id], json_response["data"].map { |v| v["id"] }
  end

  test "show returns a venue" do
    user = create_user
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner, capacity: 50)

    get "/api/v1/venues/#{venue.id}", headers: auth_headers(user)
    assert_response :success
    assert_equal venue.id, json_response["id"]
    assert_equal 50, json_response["capacity"]
  end

  test "show is public — the SDK fetches venue detail without a token" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner, capacity: 50)

    # getVenueDetailById sends no token; when this 401'd, the venue edit page's
    # loader got null back and the page 500'd — for managers included.
    get "/api/v1/venues/#{venue.id}"
    assert_response :success
    assert_equal venue.id, json_response["id"]
    assert json_response.key?("availabilities"), "the :with_availability view still renders"
  end

  test "writes stay manager-only even though reads are public" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)

    patch "/api/v1/venues/#{venue.id}", params: { venue: { capacity: 1 } }
    assert_response :unauthorized

    patch "/api/v1/venues/#{venue.id}", params: { venue: { capacity: 1 } }, headers: auth_headers(outsider)
    assert_response :forbidden

    delete "/api/v1/venues/#{venue.id}"
    assert_response :unauthorized
  end

  test "show returns require_approval/group_id/image_urls/track_ids/archived — the edit form hydrates from these" do
    owner = create_user
    group = create_group(owner: owner)
    track = create_track(group: group)
    venue = create_venue(group: group, owner: owner, require_approval: true,
      image_urls: ["https://example.com/a.png"], track_ids: [track.id])

    get "/api/v1/venues/#{venue.id}", headers: auth_headers(owner)
    assert_response :success
    assert_equal true, json_response["require_approval"]
    assert_equal group.id, json_response["group_id"]
    assert_equal ["https://example.com/a.png"], json_response["image_urls"]
    assert_equal [track.id], json_response["track_ids"]
    assert_equal false, json_response["archived"]
  end

  test "show 404s for an unknown id" do
    user = create_user
    get "/api/v1/venues/does-not-exist", headers: auth_headers(user)
    assert_response :not_found
  end

  test "name must be present" do
    owner = create_user
    group = create_group(owner: owner)

    assert_raises(ActiveRecord::RecordInvalid) do
      Venue.create!(name: nil, group: group, owner: owner)
    end
  end

  test "capacity must be a positive integer when present" do
    owner = create_user
    group = create_group(owner: owner)
    venue = Venue.new(name: "Bad Capacity", group: group, owner: owner, capacity: 0)
    assert_not venue.valid?
    assert_includes venue.errors[:capacity], "must be greater than 0"

    venue.capacity = -5
    assert_not venue.valid?
  end

  test "capacity is optional" do
    owner = create_user
    group = create_group(owner: owner)
    venue = Venue.new(name: "No Capacity", group: group, owner: owner)
    assert venue.valid?
  end

  test "create requires group admin" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)

    post "/api/v1/venues", params: { venue: { name: "New Hall", group_id: group.id, capacity: 30 } },
      headers: auth_headers(outsider)
    assert_response :forbidden

    post "/api/v1/venues", params: { venue: { name: "New Hall", group_id: group.id, capacity: 30 } },
      headers: auth_headers(owner)
    assert_response :created
    assert_equal 30, json_response["capacity"]
  end

  test "a parent-group manager cannot create a venue for a child group (interim restriction)" do
    parent_owner = create_user
    parent = create_group(owner: parent_owner)
    child = create_group(name: "child-group", parent_id: parent.id)

    post "/api/v1/venues", params: { venue: { name: "New Hall", group_id: child.id, capacity: 30 } },
      headers: auth_headers(parent_owner)
    assert_response :forbidden
  end

  test "update requires group admin" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)

    patch "/api/v1/venues/#{venue.id}", params: { venue: { capacity: 99 } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal 99, venue.reload.capacity
  end

  test "destroy is a soft delete: row survives, archived flips true, and it drops out of index" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)

    delete "/api/v1/venues/#{venue.id}", headers: auth_headers(owner)
    assert_response :no_content
    assert Venue.exists?(venue.id), "venue row must survive a soft delete"
    assert venue.reload.archived

    get "/api/v1/venues", headers: auth_headers(owner)
    assert_not_includes json_response["data"].map { |v| v["id"] }, venue.id
  end

  # GroupBlueprint :detail is the single source for every venue LIST in the app:
  # the venues page, the event editor's venue picker, and the schedule venue
  # view all read groupDetail.venues. It rendered the unfiltered `venues`
  # association, so a removed venue stayed on screen after Remove + reload and
  # was still pickable when creating an event.
  test "a removed venue drops out of the group detail venue list" do
    owner = create_user
    group = create_group(owner: owner)
    kept = create_venue(group: group, owner: owner)
    removed = create_venue(group: group, owner: owner)

    delete "/api/v1/venues/#{removed.id}", headers: auth_headers(owner)
    assert_response :no_content

    get "/api/v1/groups/#{group.id}", headers: auth_headers(owner)
    assert_response :success
    ids = json_response["venues"].map { |v| v["id"] }
    assert_includes ids, kept.id
    assert_not_includes ids, removed.id
  end

  test "an event cannot be booked into a removed venue, but one already there stays editable" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)

    event = create_event(group: group, owner: owner, venue: venue)
    delete "/api/v1/venues/#{venue.id}", headers: auth_headers(owner)
    assert_response :no_content

    # Editing an unrelated field on the already-booked event must still work.
    patch "/api/v1/events/#{event.id}", params: { event: { title: "renamed" } },
      headers: auth_headers(owner)
    assert_response :success
    assert_equal "renamed", event.reload.title

    # Booking something new into it must not.
    post "/api/v1/events", params: { event: {
      title: "new", group_id: group.id, venue_id: venue.id,
      start_time: 2.days.from_now.iso8601, end_time: 2.days.from_now.advance(hours: 1).iso8601
    } }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_equal "venue not found", json_response["error"]
  end

  # The real client submits the whole form, so venue_id comes back on every edit
  # even when the user only touched the title. That must NOT read as "booking
  # into an archived venue" — assign_attributes leaves venue_id_changed? false
  # when the value is identical, which is what makes the guard safe.
  test "resubmitting the same archived venue_id on an edit is not treated as a new booking" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)
    event = create_event(group: group, owner: owner, venue: venue)

    delete "/api/v1/venues/#{venue.id}", headers: auth_headers(owner)
    assert_response :no_content

    patch "/api/v1/events/#{event.id}", params: { event: {
      title: "renamed", venue_id: venue.id,
      start_time: event.start_time.iso8601, end_time: event.end_time.iso8601
    } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "renamed", event.reload.title
    assert_equal venue.id, event.venue_id
  end

  test "an event cannot be moved from a live venue into an archived one" do
    owner = create_user
    group = create_group(owner: owner)
    live = create_venue(group: group, owner: owner)
    archived = create_venue(group: group, owner: owner)
    event = create_event(group: group, owner: owner, venue: live)

    delete "/api/v1/venues/#{archived.id}", headers: auth_headers(owner)
    assert_response :no_content

    patch "/api/v1/events/#{event.id}", params: { event: { venue_id: archived.id } },
      headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_equal "venue not found", json_response["error"]
    assert_equal live.id, event.reload.venue_id
  end

  # Venue names used to be globally unique, so a soft-deleted venue kept holding
  # its own name against a row the user could no longer see.
  test "a venue can be recreated with the name of one that was removed" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner, name: "Main Hall")

    delete "/api/v1/venues/#{venue.id}", headers: auth_headers(owner)
    assert_response :no_content

    post "/api/v1/venues", params: { venue: { name: "Main Hall", group_id: group.id } },
      headers: auth_headers(owner)
    assert_response :created
    assert_not_equal venue.id, json_response["id"]
  end

  test "two groups can each have a venue with the same name" do
    owner = create_user
    group = create_group(owner: owner)
    other_group = create_group(owner: owner)
    create_venue(group: group, owner: owner, name: "Main Hall")

    post "/api/v1/venues", params: { venue: { name: "Main Hall", group_id: other_group.id } },
      headers: auth_headers(owner)
    assert_response :created
  end

  # Venue names are labels, not identifiers — a group running a "Room A" in two
  # buildings is ordinary, and nothing looks a venue up by name.
  test "a group can have two venues with the same name" do
    owner = create_user
    group = create_group(owner: owner)
    first = create_venue(group: group, owner: owner, name: "Main Hall")

    post "/api/v1/venues", params: { venue: { name: "Main Hall", group_id: group.id } },
      headers: auth_headers(owner)
    assert_response :created
    assert_not_equal first.id, json_response["id"]
  end

  test "set_availability replaces the venue's availability and shows it on the venue" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)

    post "/api/v1/venues/#{venue.id}/availability", params: {
      availabilities: [
        { day_of_week: "monday", intervals: [["09:00", "17:00"]] },
        { day_of_week: "tuesday", intervals: [["09:00", "12:00"]] }
      ]
    }, headers: auth_headers(owner)
    assert_response :success
    assert_equal 2, venue.reload.availabilities.count

    get "/api/v1/venues/#{venue.id}", headers: auth_headers(owner)
    assert_equal 2, json_response["availabilities"].size
  end

  test "set_availability requires group admin" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)

    post "/api/v1/venues/#{venue.id}/availability", params: { availabilities: [] },
      headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "check_availability: no availability records means open 7x24" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)

    start_at = 5.days.from_now.change(hour: 3)
    ok, = venue.check_availability(start_at, start_at + 1.hour, "UTC")
    assert ok
  end

  test "check_availability: a configured weekday closes all other weekdays" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)
    venue.availabilities.create!(day_of_week: "monday", intervals: [["09:00", "17:00"]])

    monday = Date.current.next_occurring(:monday)
    tuesday = monday + 1.day
    ok_mon, = venue.check_availability(Time.zone.local(monday.year, monday.month, monday.day, 10),
                                      Time.zone.local(monday.year, monday.month, monday.day, 11), "UTC")
    ok_tue, msg_tue = venue.check_availability(Time.zone.local(tuesday.year, tuesday.month, tuesday.day, 10),
                                              Time.zone.local(tuesday.year, tuesday.month, tuesday.day, 11), "UTC")
    assert ok_mon
    assert_not ok_tue
    assert_match "closed", msg_tue
  end

  test "check_availability: a date override takes priority over the weekly slot" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)
    monday = Date.current.next_occurring(:monday)
    venue.availabilities.create!(day_of_week: "monday", intervals: [["09:00", "17:00"]])
    # Override that specific Monday to a narrow morning window.
    venue.availabilities.create!(day: monday, intervals: [["08:00", "09:00"]])

    inside, = venue.check_availability(Time.zone.local(monday.year, monday.month, monday.day, 8, 15),
                                      Time.zone.local(monday.year, monday.month, monday.day, 8, 45), "UTC")
    outside, = venue.check_availability(Time.zone.local(monday.year, monday.month, monday.day, 10),
                                       Time.zone.local(monday.year, monday.month, monday.day, 11), "UTC")
    assert inside, "within the override window should be open"
    assert_not outside, "the weekly 09:00-17:00 slot must NOT apply once an override exists"
  end

  test "check_availability rejects a booking outside the venue's start_date/end_date window" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner,
      start_date: 10.days.from_now.to_date, end_date: 20.days.from_now.to_date)

    before_window, msg_before = venue.check_availability(5.days.from_now.change(hour: 10), 5.days.from_now.change(hour: 11), "UTC")
    within_window, = venue.check_availability(15.days.from_now.change(hour: 10), 15.days.from_now.change(hour: 11), "UTC")
    after_window, msg_after = venue.check_availability(25.days.from_now.change(hour: 10), 25.days.from_now.change(hour: 11), "UTC")

    assert_not before_window
    assert_match "not available before", msg_before
    assert within_window
    assert_not after_window
    assert_match "not available after", msg_after
  end

  test "venue end_date must be after start_date" do
    owner = create_user
    group = create_group(owner: owner)

    venue = Venue.new(name: "Bad window", group: group, owner: owner,
      start_date: 10.days.from_now.to_date, end_date: 5.days.from_now.to_date)
    assert_not venue.valid?
    assert_includes venue.errors[:end_date], "must be greater than #{10.days.from_now.to_date}"
  end
end
