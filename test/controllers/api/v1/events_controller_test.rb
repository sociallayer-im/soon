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

  test "show returns a public published event to any authenticated user" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "public")

    get "/api/v1/events/#{event.id}", headers: auth_headers(outsider)
    assert_response :success
    assert_equal event.id, json_response["id"]
  end

  test "show hides a draft event from a non-manager" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "draft")

    get "/api/v1/events/#{event.id}", headers: auth_headers(outsider)
    assert_response :forbidden

    get "/api/v1/events/#{event.id}", headers: auth_headers(owner)
    assert_response :success
  end

  test "show hides a private event from a non-member but shows it to a member" do
    owner = create_user
    member = create_user
    outsider = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    event = create_event(group: group, owner: owner, status: "published", visibility: "private")

    get "/api/v1/events/#{event.id}", headers: auth_headers(outsider)
    assert_response :forbidden

    get "/api/v1/events/#{event.id}", headers: auth_headers(member)
    assert_response :success
  end

  test "index does not leak draft or private events to ordinary members" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    published = create_event(group: group, owner: owner, status: "published", visibility: "public")
    create_event(group: group, owner: owner, status: "draft")
    create_event(group: group, owner: owner, status: "published", visibility: "private")

    get "/api/v1/events", headers: auth_headers(member)
    assert_response :success
    ids = json_response["data"].map { |e| e["id"] }
    assert_equal [published.id], ids
  end

  test "index shows a group admin the group's draft and private events" do
    owner = create_user
    group = create_group(owner: owner)
    create_event(group: group, owner: owner, status: "published")
    create_event(group: group, owner: owner, status: "draft")

    get "/api/v1/events", headers: auth_headers(owner)
    assert_response :success
    assert_equal 2, json_response["data"].size
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

  test "create persists image_url and notes (were previously dropped)" do
    owner = create_user
    group = create_group(owner: owner)

    post "/api/v1/events", params: {
      event: { title: "Meetup", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour,
                group_id: group.id, image_url: "https://cdn.test/cover.png", notes: "backstage info" }
    }, headers: auth_headers(owner)
    assert_response :created
    event = Event.find(json_response["id"])
    assert_equal "https://cdn.test/cover.png", event.image_url
    assert_equal "backstage info", event.notes
  end

  test "create ignores pinned from a non-manager member" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")

    post "/api/v1/events", params: {
      event: { title: "Meetup", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour,
                group_id: group.id, pinned: true }
    }, headers: auth_headers(member)
    assert_response :created
    assert_not Event.find(json_response["id"]).pinned, "a non-manager must not be able to feature their event"
  end

  test "create honors pinned from a group manager" do
    owner = create_user
    group = create_group(owner: owner)

    post "/api/v1/events", params: {
      event: { title: "Meetup", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour,
                group_id: group.id, pinned: true }
    }, headers: auth_headers(owner)
    assert_response :created
    assert Event.find(json_response["id"]).pinned
  end

  test "update ignores pinned from a non-manager owner but keeps their other edits" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    event = create_event(group: group, owner: member)

    patch "/api/v1/events/#{event.id}", params: {
      event: { title: "Renamed", pinned: true }
    }, headers: auth_headers(member)
    assert_response :success
    event.reload
    assert_equal "Renamed", event.title
    assert_not event.pinned
  end

  test "create inherits the group's timezone when none is given" do
    owner = create_user
    group = create_group(owner: owner, timezone: "Asia/Shanghai")

    post "/api/v1/events", params: {
      event: { title: "Meetup", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour, group_id: group.id }
    }, headers: auth_headers(owner)
    assert_response :created
    assert_equal "Asia/Shanghai", Event.find(json_response["id"]).timezone
  end

  test "create keeps an explicit timezone over the group's" do
    owner = create_user
    group = create_group(owner: owner, timezone: "Asia/Shanghai")

    post "/api/v1/events", params: {
      event: { title: "Meetup", timezone: "America/New_York",
               start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour, group_id: group.id }
    }, headers: auth_headers(owner)
    assert_response :created
    assert_equal "America/New_York", Event.find(json_response["id"]).timezone
  end

  test "create interprets a naive start_time in the event's timezone" do
    owner = create_user
    group = create_group(owner: owner, timezone: "Asia/Shanghai")

    post "/api/v1/events", params: {
      event: { title: "SH", start_time: "2026-07-16 14:00:00", end_time: "2026-07-16 16:00:00", group_id: group.id }
    }, headers: auth_headers(owner)
    assert_response :created
    event = Event.find(json_response["id"])
    # 14:00 Shanghai (UTC+8) == 06:00 UTC — not stored as 14:00 UTC.
    assert_equal Time.utc(2026, 7, 16, 6, 0, 0), event.start_time.utc
    assert_equal 14, event.local_start.hour
  end

  test "create respects an explicit offset in the time string over the zone" do
    owner = create_user
    group = create_group(owner: owner, timezone: "Asia/Shanghai")

    post "/api/v1/events", params: {
      event: { title: "Offset", start_time: "2026-07-16T14:00:00-04:00",
               end_time: "2026-07-16T16:00:00-04:00", group_id: group.id }
    }, headers: auth_headers(owner)
    assert_response :created
    # -04:00 in the string wins: 14:00 EDT == 18:00 UTC.
    assert_equal Time.utc(2026, 7, 16, 18, 0, 0), Event.find(json_response["id"]).start_time.utc
  end

  test "update reinterprets a naive start_time in the event's existing zone" do
    owner = create_user
    group = create_group(owner: owner, timezone: "Asia/Shanghai")
    event = create_event(group: group, owner: owner) # inherits Asia/Shanghai

    patch "/api/v1/events/#{event.id}",
      params: { event: { start_time: "2026-07-16 09:00:00", end_time: "2026-07-16 10:00:00" } },
      headers: auth_headers(owner)
    assert_response :success
    # 09:00 Shanghai == 01:00 UTC
    assert_equal Time.utc(2026, 7, 16, 1, 0, 0), event.reload.start_time.utc
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

  test "destroy soft-cancels (status cancelled) instead of deleting, and keeps participants/tickets" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published")
    attendee = create_user
    participant = create_participant(event: event, user: attendee)

    delete "/api/v1/events/#{event.id}", headers: auth_headers(outsider)
    assert_response :forbidden

    delete "/api/v1/events/#{event.id}", headers: auth_headers(owner)
    assert_response :no_content
    assert Event.exists?(event.id), "event row must survive a cancel"
    assert_equal "cancelled", event.reload.status
    assert Participant.exists?(participant.id), "participants must not be cascade-deleted"
  end

  test "create rejects an invalid status" do
    owner = create_user
    group = create_group(owner: owner)

    post "/api/v1/events", params: {
      event: { title: "Bad status", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour,
               group_id: group.id, status: "totally-made-up" }
    }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
  end

  test "update cannot move an event into another group" do
    owner = create_user
    group = create_group(owner: owner)
    other_group = create_group # attacker is not a member/admin here
    event = create_event(group: group, owner: owner)

    patch "/api/v1/events/#{event.id}",
      params: { event: { group_id: other_group.id } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal group.id, event.reload.group_id, "group_id must be immutable on update"
  end

  # ---------------------------------------------------------------- venue booking

  test "create rejects a venue that belongs to another group" do
    owner = create_user
    group = create_group(owner: owner)
    other_venue = create_venue(group: create_group, owner: create_user)

    post "/api/v1/events", params: {
      event: { title: "X", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour,
               group_id: group.id, venue_id: other_venue.id }
    }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "venue does not belong", json_response["error"]
  end

  test "create rejects a double-booking of the same venue" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)
    start_at = 2.days.from_now.change(hour: 10)
    create_event(group: group, owner: owner, venue: venue, status: "published",
                 start_time: start_at, end_time: start_at + 2.hours)

    post "/api/v1/events", params: {
      event: { title: "Overlap", group_id: group.id, venue_id: venue.id,
               start_time: start_at + 1.hour, end_time: start_at + 3.hours }
    }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "already booked", json_response["error"]
  end

  test "create allows a non-overlapping booking of the same venue" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)
    start_at = 2.days.from_now.change(hour: 10)
    create_event(group: group, owner: owner, venue: venue, status: "published",
                 start_time: start_at, end_time: start_at + 2.hours)

    post "/api/v1/events", params: {
      event: { title: "Later", group_id: group.id, venue_id: venue.id,
               start_time: start_at + 3.hours, end_time: start_at + 4.hours }
    }, headers: auth_headers(owner)
    assert_response :created
  end

  test "create rejects a booking outside the venue's configured weekly hours" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)
    # Only open Mondays 09:00-12:00
    venue.availabilities.create!(day_of_week: "monday", intervals: [["09:00", "12:00"]])

    # Next Monday 15:00 (outside the 09:00-12:00 window)
    monday = Date.current.next_occurring(:monday)
    start_at = Time.zone.local(monday.year, monday.month, monday.day, 15, 0)

    post "/api/v1/events", params: {
      event: { title: "Off-hours", group_id: group.id, venue_id: venue.id, timezone: "UTC",
               start_time: start_at, end_time: start_at + 1.hour }
    }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "closed", json_response["error"]
  end

  test "create rejects when event capacity exceeds venue capacity" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner, capacity: 20)

    post "/api/v1/events", params: {
      event: { title: "Too big", group_id: group.id, venue_id: venue.id, max_participant: 100,
               start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour }
    }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "capacity", json_response["error"]
  end

  test "index is public but write actions require authentication" do
    get "/api/v1/events"
    assert_response :success

    post "/api/v1/events", params: { event: { title: "X" } }
    assert_response :unauthorized
  end

  test "create rejects a track that belongs to another group" do
    owner = create_user
    group = create_group(owner: owner)
    other_track = create_track(group: create_group)

    post "/api/v1/events", params: {
      event: { title: "X", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour,
               group_id: group.id, track_id: other_track.id }
    }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "track does not belong", json_response["error"]
  end

  test "update re-validates a venue against the event's group" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    foreign_venue = create_venue(group: create_group, owner: create_user)

    patch "/api/v1/events/#{event.id}", params: { event: { venue_id: foreign_venue.id } }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "venue does not belong", json_response["error"]
    assert_nil event.reload.venue_id
  end

  test "update does not flag the event's own booking as a double-booking" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)
    start_at = 2.days.from_now.change(hour: 10)
    event = create_event(group: group, owner: owner, venue: venue, status: "published",
                         start_time: start_at, end_time: start_at + 2.hours)

    # Editing the same event (its slot overlaps only itself) must succeed —
    # check_availability excludes the event being updated.
    patch "/api/v1/events/#{event.id}", params: { event: { title: "Renamed", venue_id: venue.id } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "Renamed", event.reload.title
  end

  test "update rejects moving into a slot already booked by another event" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)
    start_at = 2.days.from_now.change(hour: 10)
    create_event(group: group, owner: owner, venue: venue, status: "published",
                 start_time: start_at, end_time: start_at + 2.hours)
    mover = create_event(group: group, owner: owner, start_time: start_at + 5.hours, end_time: start_at + 6.hours)

    patch "/api/v1/events/#{mover.id}", params: {
      event: { venue_id: venue.id, start_time: start_at + 1.hour, end_time: start_at + 3.hours }
    }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "already booked", json_response["error"]
  end

  test "destroy (cancel) requires owner or group admin" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)

    delete "/api/v1/events/#{event.id}", headers: auth_headers(outsider)
    assert_response :forbidden
    assert_not_equal "cancelled", event.reload.status
  end
end
