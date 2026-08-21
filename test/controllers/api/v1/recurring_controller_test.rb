require "test_helper"

class Api::V1::RecurringControllerTest < ActionDispatch::IntegrationTest
  def setup
    @owner = create_user
    @group = create_group(owner: @owner)
  end

  def base_start = 3.days.from_now.change(hour: 10)

  # A weekly 10:00 America/New_York series that crosses the spring-forward DST
  # boundary (2026-03-08) must keep every occurrence at 10:00 *local* — advancing
  # in the zone, not in UTC. Before the fix, occurrences after the transition
  # drifted to 09:00 local.
  test "recurring keeps wall-clock time stable across a DST transition" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 3, timezone: "America/New_York",
      # naive local time — interpreted in the series' zone
      start_time: "2026-03-01 10:00:00", end_time: "2026-03-01 12:00:00", title: "Weekly", status: "published"
    }, headers: auth_headers(@owner)
    assert_response :created

    events = Recurring.find(json_response["id"]).events.order(:start_time)
    local_hours = events.map { |e| e.start_time.in_time_zone("America/New_York").hour }
    assert_equal [10, 10, 10], local_hours, "every occurrence should stay at 10:00 local"

    # And the absolute UTC instants shift by an hour across the DST boundary:
    # 10:00 EST = 15:00 UTC (before), 10:00 EDT = 14:00 UTC (after).
    assert_equal 15, events.first.start_time.utc.hour
    assert_equal 14, events.last.start_time.utc.hour
  end

  # event_attributes used to omit image_url/image_note, so every occurrence in
  # a new series was created with no cover regardless of what the form sent —
  # the single-event path (events_controller#event_params) never had this gap.
  test "a new series carries the cover image onto every occurrence" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 3,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601,
      title: "Weekly", image_url: "https://example.com/cover.png", image_note: "credit: someone"
    }, headers: auth_headers(@owner)
    assert_response :created

    events = Event.where(recurring_id: json_response["id"])
    assert_equal 3, events.count
    assert events.all? { |e| e.image_url == "https://example.com/cover.png" }
    assert events.all? { |e| e.image_note == "credit: someone" }
  end

  test "updating a series with selector all can set the cover image on every occurrence" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "Orig"
    }, headers: auth_headers(@owner)
    recurring_id = json_response["id"]

    patch "/api/v1/recurring/#{recurring_id}", params: {
      selector: "all", image_url: "https://example.com/new-cover.png"
    }, headers: auth_headers(@owner)
    assert_response :success

    events = Event.where(recurring_id: recurring_id)
    assert events.all? { |e| e.image_url == "https://example.com/new-cover.png" }
  end

  test "a naive start_time is interpreted in the series timezone, not UTC" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "day", event_count: 1, timezone: "Asia/Shanghai",
      start_time: "2026-07-16 14:00:00", end_time: "2026-07-16 16:00:00", title: "SH"
    }, headers: auth_headers(@owner)
    assert_response :created

    event = Recurring.find(json_response["id"]).events.first
    # 14:00 Shanghai (UTC+8) == 06:00 UTC
    assert_equal Time.utc(2026, 7, 16, 6, 0, 0), event.start_time.utc
  end

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

  test "create allows a venue owned by a venue_union partner group" do
    partner_group = create_group
    @group.update!(venue_union: [@group.id, partner_group.id])
    partner_venue = create_venue(group: partner_group, owner: create_user)

    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2, venue_id: partner_venue.id,
      start_time: base_start.iso8601, end_time: (base_start + 2.hours).iso8601, title: "Cross-group"
    }, headers: auth_headers(@owner)
    assert_response :created

    events = Recurring.find(json_response["id"]).events
    assert events.all? { |e| e.venue_id == partner_venue.id }
  end

  test "create rejects a venue outside the venue_union set" do
    unrelated_venue = create_venue(group: create_group, owner: create_user)

    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2, venue_id: unrelated_venue.id,
      start_time: base_start.iso8601, end_time: (base_start + 2.hours).iso8601, title: "Bad venue"
    }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_match "venue does not belong", json_response["error"]
  end

  test "create succeeds for a non-member when the group's can_publish_event is everyone (the default)" do
    outsider = create_user
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "X"
    }, headers: auth_headers(outsider)
    assert_response :created
  end

  test "create is forbidden for a non-member when can_publish_event is manager" do
    restricted_group = create_group(owner: @owner, can_publish_event: "manager")
    outsider = create_user
    post "/api/v1/recurring", params: {
      group_id: restricted_group.id, interval: "week", event_count: 2,
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

  # The event detail page server-renders the "Repeating Events" list for
  # signed-out visitors with no token; while this 401'd, every anonymous view of
  # a recurring event 500'd the whole page.
  test "show is readable anonymously, exposing only the visible occurrences" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "day", event_count: 2, status: "published",
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "Daily"
    }, headers: auth_headers(@owner)
    assert_response :created
    recurring_id = json_response["id"]

    get "/api/v1/recurring/#{recurring_id}"
    assert_response :success
    assert_equal 2, json_response["events"].size

    # A draft occurrence is the owner's business only — it must not leak to an
    # anonymous reader, while the owner still sees the whole series.
    Recurring.find(recurring_id).events.order(:start_time).first.update!(status: "draft")

    get "/api/v1/recurring/#{recurring_id}"
    assert_response :success
    assert_equal 1, json_response["events"].size

    get "/api/v1/recurring/#{recurring_id}", headers: auth_headers(@owner)
    assert_response :success
    assert_equal 2, json_response["events"].size
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

  test "create persists the resolved timezone onto every occurrence and the series" do
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2, timezone: "Asia/Shanghai",
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "TZ"
    }, headers: auth_headers(@owner)
    assert_response :created

    recurring = Recurring.find(json_response["id"])
    assert_equal "Asia/Shanghai", recurring.timezone
    assert recurring.events.all? { |e| e.timezone == "Asia/Shanghai" }
  end

  test "create with no explicit timezone persists the group's timezone onto every occurrence" do
    @group.update!(timezone: "America/New_York")
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2,
      start_time: base_start.iso8601, end_time: (base_start + 1.hour).iso8601, title: "TZ"
    }, headers: auth_headers(@owner)
    assert_response :created

    recurring = Recurring.find(json_response["id"])
    assert_equal "America/New_York", recurring.timezone
    assert recurring.events.all? { |e| e.timezone == "America/New_York" }
  end

  test "update re-checks availability against the existing venue even when venue_id isn't re-sent" do
    venue = create_venue(group: @group, owner: @owner)
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2, venue_id: venue.id, timezone: "UTC",
      start_time: base_start.iso8601, end_time: (base_start + 2.hours).iso8601, title: "Series"
    }, headers: auth_headers(@owner)
    recurring_id = json_response["id"]

    # Pre-book the venue at the time we're about to shift the series into —
    # 1 day later than the current occurrences, with an unrelated event.
    conflict_start = base_start + 1.day
    create_event(group: @group, owner: @owner, venue: venue, status: "published",
                 start_time: conflict_start, end_time: conflict_start + 2.hours)

    # Shift every occurrence by exactly 1 day — no venue_id in the request at
    # all, only a time shift. Must still be checked against the venue the
    # series already has.
    patch "/api/v1/recurring/#{recurring_id}", params: { selector: "all", start_time_diff: 1.day.to_i, end_time_diff: 1.day.to_i },
      headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_match "already booked", json_response["error"]

    # And the events were NOT shifted — the whole update rolled back.
    events = Event.where(recurring_id: recurring_id).order(:start_time)
    assert_equal base_start.to_i, events.first.start_time.to_i
  end

  # Removing a venue is a soft delete, and the client resubmits the whole form,
  # so venue_id comes back on edits that don't touch the venue. A series whose
  # venue was removed afterwards must stay editable.
  test "update accepts the series' own venue_id after that venue was archived" do
    venue = create_venue(group: @group, owner: @owner)
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2, venue_id: venue.id, timezone: "UTC",
      start_time: base_start.iso8601, end_time: (base_start + 2.hours).iso8601, title: "Series"
    }, headers: auth_headers(@owner)
    assert_response :created
    recurring_id = json_response["id"]

    delete "/api/v1/venues/#{venue.id}", headers: auth_headers(@owner)
    assert_response :no_content

    patch "/api/v1/recurring/#{recurring_id}",
      params: { selector: "all", venue_id: venue.id, title: "Renamed" },
      headers: auth_headers(@owner)
    assert_response :success
    assert Event.where(recurring_id: recurring_id).all? { |e| e.title == "Renamed" }
    assert Event.where(recurring_id: recurring_id).all? { |e| e.venue_id == venue.id }
  end

  test "update refuses to move a series into an archived venue" do
    live = create_venue(group: @group, owner: @owner)
    archived = create_venue(group: @group, owner: @owner)
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2, venue_id: live.id, timezone: "UTC",
      start_time: base_start.iso8601, end_time: (base_start + 2.hours).iso8601, title: "Series"
    }, headers: auth_headers(@owner)
    assert_response :created
    recurring_id = json_response["id"]

    delete "/api/v1/venues/#{archived.id}", headers: auth_headers(@owner)
    assert_response :no_content

    patch "/api/v1/recurring/#{recurring_id}",
      params: { selector: "all", venue_id: archived.id },
      headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_match "venue does not belong", json_response["error"]
    assert Event.where(recurring_id: recurring_id).all? { |e| e.venue_id == live.id }
  end

  test "create refuses to book a series into an archived venue" do
    venue = create_venue(group: @group, owner: @owner)
    delete "/api/v1/venues/#{venue.id}", headers: auth_headers(@owner)
    assert_response :no_content

    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2, venue_id: venue.id, timezone: "UTC",
      start_time: base_start.iso8601, end_time: (base_start + 2.hours).iso8601, title: "Series"
    }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_match "venue does not belong", json_response["error"]
  end

  test "update accepts a time shift that still fits the existing venue's hours" do
    venue = create_venue(group: @group, owner: @owner)
    venue.availabilities.create!(day_of_week: base_start.strftime("%A").downcase, intervals: [["00:00", "23:59"]])
    post "/api/v1/recurring", params: {
      group_id: @group.id, interval: "week", event_count: 2, venue_id: venue.id, timezone: "UTC",
      start_time: base_start.iso8601, end_time: (base_start + 2.hours).iso8601, title: "Series"
    }, headers: auth_headers(@owner)
    recurring_id = json_response["id"]

    patch "/api/v1/recurring/#{recurring_id}", params: { selector: "all", start_time_diff: 3600, end_time_diff: 3600 },
      headers: auth_headers(@owner)
    assert_response :success
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
