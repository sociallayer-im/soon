require "test_helper"

class Api::V1::RecurringControllerTest < ActionDispatch::IntegrationTest
  def setup
    @owner = create_user
    @group = create_group(owner: @owner)
  end

  def base_start = 3.days.from_now.change(hour: 10)

  test "create generates one event per weekly occurrence" do
    assert_difference -> { Event.count }, 4 do
      post "/api/v1/recurring", params: {
        group_id: @group.id, interval: "week", event_count: 4,
        start_time: base_start.iso8601, end_time: (base_start + 2.hours).iso8601,
        title: "Weekly Standup", status: "published"
      }, headers: auth_headers(@owner)
    end
    assert_response :created

    recurring = Recurring.find(json_response["id"])
    events = recurring.events.order(:start_time)
    assert_equal 4, events.size
    assert_equal (base_start + 3.weeks).to_i, events.last.start_time.to_i
    assert events.all? { |e| e.title == "Weekly Standup" && e.status == "published" }
  end

  test "create requires group membership" do
    outsider = create_user
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "X"
    }, headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "create rejects an invalid interval" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "fortnightly", event_count: 2,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "X"
    }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
  end

  test "create is atomic: a mid-series venue conflict creates nothing" do
    venue = create_venue(group: @group, owner: @owner)
    # Pre-book the venue at the 3rd weekly occurrence's time.
    conflict_start = base_start + 2.weeks
    create_event(group: @group, owner: @owner, venue: venue, status: "published",
                 start_time: conflict_start, end_time: conflict_start + 2.hours)

    assert_no_difference -> { Recurring.count } do
      assert_no_difference -> { Event.where(recurring_id: nil).count } do
        post "/api/v1/recurring", params: {
          group_id: @group.id, interval: "week", event_count: 4, venue_id: venue.id, timezone: "UTC",
          start_time: base_start.iso8601, end_time: (base_start + 2.hours).iso8601, title: "Series"
        }, headers: auth_headers(@owner)
      end
    end
    assert_response :unprocessable_entity
    assert_match "already booked", json_response["error"]
  end

  test "update with selector all shifts every occurrence" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 3,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "Orig"
    }, headers: auth_headers(@owner)
    recurring_id = json_response["id"]
    firsts = Event.where(recurring_id: recurring_id).order(:start_time).pluck(:start_time)

    patch "/api/v1/recurring/#{recurring_id}", params: {
      selector: "all", start_time_diff: 3600, end_time_diff: 3600, title: "Renamed"
    }, headers: auth_headers(@owner)
    assert_response :success

    events = Event.where(recurring_id: recurring_id).order(:start_time)
    assert events.all? { |e| e.title == "Renamed" }
    assert_equal firsts.map { |t| t.to_i + 3600 }, events.map { |e| e.start_time.to_i }
  end

  test "update with selector after only touches the pivot occurrence onward" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 3,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "Orig"
    }, headers: auth_headers(@owner)
    recurring_id = json_response["id"]
    events = Event.where(recurring_id: recurring_id).order(:start_time).to_a
    pivot = events[1]

    patch "/api/v1/recurring/#{recurring_id}", params: {
      selector: "after", after_event_id: pivot.id, title: "Changed"
    }, headers: auth_headers(@owner)
    assert_response :success

    assert_equal "Orig", events[0].reload.title
    assert_equal "Changed", events[1].reload.title
    assert_equal "Changed", events[2].reload.title
  end

  test "cancel soft-cancels the whole series without destroying events" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "day", event_count: 3,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "Daily"
    }, headers: auth_headers(@owner)
    recurring_id = json_response["id"]
    ids = Event.where(recurring_id: recurring_id).pluck(:id)

    assert_no_difference -> { Event.count } do
      post "/api/v1/recurring/#{recurring_id}/cancel", params: { selector: "all" },
        headers: auth_headers(@owner)
    end
    assert_response :success
    assert Event.where(id: ids).all? { |e| e.status == "cancelled" }
  end

  test "cancel requires owner or group admin" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "day", event_count: 2,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "Daily"
    }, headers: auth_headers(@owner)
    recurring_id = json_response["id"]
    outsider = create_user

    post "/api/v1/recurring/#{recurring_id}/cancel", params: { selector: "all" },
      headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "cancelling a Recurring row nullifies events instead of destroying them" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "day", event_count: 2,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "Daily"
    }, headers: auth_headers(@owner)
    recurring = Recurring.find(json_response["id"])
    ids = recurring.events.pluck(:id)

    recurring.destroy
    assert_equal ids.sort, Event.where(id: ids).pluck(:id).sort, "events must survive"
    assert Event.where(id: ids).all? { |e| e.recurring_id.nil? }
  end

  test "create generates one event per monthly occurrence" do
    assert_difference -> { Event.count }, 3 do
      post "/api/v1/recurring", params: {
        group_id: @group.id, interval: "month", event_count: 3,
        start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "Monthly"
      }, headers: auth_headers(@owner)
    end
    assert_response :created
    events = Recurring.find(json_response["id"]).events.order(:start_time)
    assert_equal (base_start + 2.months).to_i, events.last.start_time.to_i
  end

  test "create rejects a non-positive event_count" do
    assert_no_difference -> { Recurring.count } do
      post "/api/v1/recurring", params: {
        group_id: @group.id, interval: "week", event_count: 0,
        start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "None"
      }, headers: auth_headers(@owner)
    end
    assert_response :unprocessable_entity
    assert_match "event_count", json_response["error"]
  end

  test "create rejects an end_time that is not after start_time" do
    assert_no_difference -> { Recurring.count } do
      post "/api/v1/recurring", params: {
        group_id: @group.id, interval: "week", event_count: 2,
        start_time: base_start.iso8601, end_time: base_start.iso8601, title: "Zero-length"
      }, headers: auth_headers(@owner)
    end
    assert_response :unprocessable_entity
    assert_match "start_time/end_time", json_response["error"]
  end

  test "create 404s for an unknown group_id" do
    post "/api/v1/recurring", params: {
      group_id: "nope", interval: "week", event_count: 2,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "X"
    }, headers: auth_headers(@owner)
    assert_response :not_found
  end

  test "show returns the series with its events, 404 for unknown" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "day", event_count: 2,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "Daily"
    }, headers: auth_headers(@owner)
    recurring_id = json_response["id"]

    get "/api/v1/recurring/#{recurring_id}", headers: auth_headers(@owner)
    assert_response :success
    assert_equal 2, json_response["events"].size

    get "/api/v1/recurring/does-not-exist", headers: auth_headers(@owner)
    assert_response :not_found
  end

  test "update requires owner or group admin" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "day", event_count: 2,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "Daily"
    }, headers: auth_headers(@owner)
    recurring_id = json_response["id"]
    outsider = create_user

    patch "/api/v1/recurring/#{recurring_id}", params: { selector: "all", title: "Hijacked" },
      headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "update with a new venue re-checks availability and rejects a conflict" do
    venue = create_venue(group: @group, owner: @owner)
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2,
      start_time: base_start.iso8601, end_time: (base_start + 2.hours).iso8601, title: "Series"
    }, headers: auth_headers(@owner)
    recurring_id = json_response["id"]
    # Pre-book the venue over the first occurrence's slot with an unrelated event.
    create_event(group: @group, owner: @owner, venue: venue, status: "published",
                 start_time: base_start, end_time: base_start + 2.hours)

    patch "/api/v1/recurring/#{recurring_id}", params: { selector: "all", venue_id: venue.id },
      headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_match "already booked", json_response["error"]
  end
end
