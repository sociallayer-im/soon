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

  test "show 404s for an unknown id" do
    user = create_user
    get "/api/v1/venues/does-not-exist", headers: auth_headers(user)
    assert_response :not_found
  end

  test "name must be unique" do
    owner = create_user
    group = create_group(owner: owner)
    create_venue(group: group, owner: owner, name: "Duplicate Venue")

    assert_raises(ActiveRecord::RecordInvalid) do
      Venue.create!(name: "Duplicate Venue", group: group, owner: owner)
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
end
