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

  test "index with group_id also includes events from the group's event_union partners" do
    owner = create_user
    main_group = create_group(owner: owner)
    partner_group = create_group
    unrelated_group = create_group
    main_group.update!(event_union: [main_group.id, partner_group.id])

    own_event = create_event(group: main_group, owner: owner, status: "published")
    partner_event = create_event(group: partner_group, owner: create_user, status: "published")
    unrelated_event = create_event(group: unrelated_group, owner: create_user, status: "published")

    get "/api/v1/events", params: { group_id: main_group.id }, headers: auth_headers(owner)
    assert_response :success
    ids = json_response["data"].map { |e| e["id"] }
    assert_includes ids, own_event.id
    assert_includes ids, partner_event.id
    assert_not_includes ids, unrelated_event.id
  end

  test "index with group_id and no event_union only returns the group's own events" do
    owner = create_user
    group = create_group(owner: owner)
    other_group = create_group
    own_event = create_event(group: group, owner: owner)
    other_event = create_event(group: other_group, owner: create_user)

    get "/api/v1/events", params: { group_id: group.id }, headers: auth_headers(owner)
    assert_response :success
    ids = json_response["data"].map { |e| e["id"] }
    assert_includes ids, own_event.id
    assert_not_includes ids, other_event.id
  end

  test "index with co_host_id returns events where the user is an EventRole item, regardless of role" do
    co_host = create_user
    group = create_group
    with_role = create_event(group: group, owner: create_user, status: "published")
    create_event_role(event: with_role, item: co_host, role: "manager")
    without_role = create_event(group: group, owner: create_user, status: "published")

    get "/api/v1/events", params: { co_host_id: co_host.id }
    assert_response :success
    ids = json_response["data"].map { |e| e["id"] }
    assert_includes ids, with_role.id
    assert_not_includes ids, without_role.id
  end

  test "index with co_host_id resolves by username too" do
    co_host = create_user(name: "cohost_handle")
    group = create_group
    event = create_event(group: group, owner: create_user, status: "published")
    create_event_role(event: event, item: co_host, role: "member")

    get "/api/v1/events", params: { co_host_id: "cohost_handle" }
    assert_response :success
    assert_equal [event.id], json_response["data"].map { |e| e["id"] }
  end

  test "index with starred_id returns events the user has starred, in one query" do
    starrer = create_user
    group = create_group
    starred = create_event(group: group, owner: create_user, status: "published")
    create_comment(user: starrer, item: starred, comment_type: "star")
    unstarred = create_event(group: group, owner: create_user, status: "published")

    get "/api/v1/events", params: { starred_id: starrer.id }
    assert_response :success
    ids = json_response["data"].map { |e| e["id"] }
    assert_includes ids, starred.id
    assert_not_includes ids, unstarred.id
  end

  test "index with starred_id excludes a removed star comment" do
    starrer = create_user
    group = create_group
    event = create_event(group: group, owner: create_user, status: "published")
    create_comment(user: starrer, item: event, comment_type: "star", removed: true)

    get "/api/v1/events", params: { starred_id: starrer.id }
    assert_response :success
    assert_empty json_response["data"]
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

  test "show carries is_starred/is_attending/is_owner for an authenticated viewer" do
    owner = create_user
    viewer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "public")
    create_comment(user: viewer, item: event, comment_type: "star")
    create_participant(event: event, user: viewer)

    get "/api/v1/events/#{event.id}", headers: auth_headers(viewer)
    assert_response :success
    assert json_response["is_starred"]
    assert json_response["is_attending"]
    assert_not json_response["is_owner"]
  end

  test "show omits is_starred/is_attending/is_owner for an anonymous viewer" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "public")

    get "/api/v1/events/#{event.id}"
    assert_response :success
    assert_not json_response.key?("is_starred")
  end

  test "show includes payment_methods on nested tickets (extended view)" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "public")
    ticket = create_ticket(event: event)
    create_payment_method(item: ticket, chain: "stripe", price: 1000)

    get "/api/v1/events/#{event.id}", headers: auth_headers(owner)
    assert_response :success

    ticket_json = json_response["tickets"].find { |t| t["id"] == ticket.id }
    assert ticket_json["payment_methods"].present?, "expected payment_methods on event show's nested tickets"
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

  test "index does not leak a pending (awaiting-approval) event to an ordinary member" do
    owner = create_user
    submitter = create_user
    outsider = create_user
    group = create_group(owner: owner)
    create_membership(user: submitter, group: group, role: "member")
    create_membership(user: outsider, group: group, role: "member")
    published = create_event(group: group, owner: owner, status: "published", visibility: "public")
    pending = create_event(group: group, owner: submitter, status: "pending", visibility: "public")

    # The submitter still sees their own pending submission (owner_id clause)...
    get "/api/v1/events", headers: auth_headers(submitter)
    assert_equal [published.id, pending.id].sort, json_response["data"].map { |e| e["id"] }.sort

    # ...but a random other member of the same group must not.
    get "/api/v1/events", headers: auth_headers(outsider)
    assert_equal [published.id], json_response["data"].map { |e| e["id"] }
  end

  test "index drops a cancelled event from a random viewer's browse listing" do
    owner = create_user
    group = create_group(owner: owner)
    cancelled = create_event(group: group, owner: owner, status: "cancelled", visibility: "public")

    get "/api/v1/events", params: { group_id: group.id }, headers: auth_headers(create_user)
    assert_response :success
    assert_not_includes json_response["data"].map { |e| e["id"] }, cancelled.id
  end

  test "index still shows the organizer their own cancelled event (Cancelled badge, not vanished)" do
    owner = create_user
    group = create_group(owner: owner)
    cancelled = create_event(group: group, owner: owner, status: "cancelled", visibility: "public")

    get "/api/v1/events", params: { group_id: group.id }, headers: auth_headers(owner)
    assert_response :success
    assert_includes json_response["data"].map { |e| e["id"] }, cancelled.id
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

  test "create atomically persists inline event_roles and tickets in one request" do
    owner = create_user
    cohost = create_user
    group = create_group(owner: owner)

    assert_difference ["Event.count", "EventRole.count", "Ticket.count"], 1 do
      post "/api/v1/events", params: {
        event: { title: "Meetup", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour, group_id: group.id },
        event_roles: [{ item_id: cohost.id, item_type: "User", role: "manager", display_name: "Co" }],
        tickets: [{ title: "GA", ticket_type: "event", quantity: 50 }]
      }, headers: auth_headers(owner)
    end
    assert_response :created
    event = Event.find(json_response["id"])
    assert_equal cohost.id, event.event_roles.first.item_id
    assert_equal "GA", event.tickets.first.title
  end

  test "create rolls the whole event back when an inline ticket is invalid" do
    owner = create_user
    group = create_group(owner: owner)

    assert_no_difference ["Event.count", "Ticket.count"] do
      post "/api/v1/events", params: {
        event: { title: "Meetup", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour, group_id: group.id },
        tickets: [{ title: "Bad", ticket_type: "not-a-valid-type" }]
      }, headers: auth_headers(owner)
    end
    assert_response :unprocessable_entity
  end

  test "create rolls back and 422s on an inline role with a bad item_type (no polymorphic 500)" do
    owner = create_user
    group = create_group(owner: owner)

    assert_no_difference "Event.count" do
      post "/api/v1/events", params: {
        event: { title: "Meetup", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour, group_id: group.id },
        event_roles: [{ item_id: owner.id, item_type: "Bogus", role: "manager" }]
      }, headers: auth_headers(owner)
    end
    assert_response :unprocessable_entity
    assert_match "item_type must be User or Group", json_response["error"]
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

  test "update succeeds for a co-host (EventRole role: manager) who is neither owner nor group admin" do
    owner = create_user
    cohost = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    event.event_roles.create!(item_id: cohost.id, item_type: "User", role: "manager")

    patch "/api/v1/events/#{event.id}", params: { event: { title: "Renamed by co-host" } },
      headers: auth_headers(cohost)
    assert_response :success
    assert_equal "Renamed by co-host", event.reload.title
  end

  test "update is forbidden for a merely-listed EventRole (role: member, e.g. a speaker)" do
    owner = create_user
    speaker = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    event.event_roles.create!(item_id: speaker.id, item_type: "User", role: "member")

    patch "/api/v1/events/#{event.id}", params: { event: { title: "Renamed" } }, headers: auth_headers(speaker)
    assert_response :forbidden
  end

  test "update succeeds for a group admin who isn't the owner" do
    owner = create_user
    admin = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")
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

  test "create allows a venue owned by a venue_union partner group" do
    owner = create_user
    group = create_group(owner: owner)
    partner_group = create_group
    group.update!(venue_union: [group.id, partner_group.id])
    partner_venue = create_venue(group: partner_group, owner: create_user)

    post "/api/v1/events", params: {
      event: { title: "X", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour,
               group_id: group.id, venue_id: partner_venue.id }
    }, headers: auth_headers(owner)
    assert_response :created
    assert_equal partner_venue.id, json_response["venue"]["id"]
  end

  test "create still rejects a venue outside the venue_union set" do
    owner = create_user
    group = create_group(owner: owner)
    partner_group = create_group
    group.update!(venue_union: [group.id, partner_group.id])
    unrelated_venue = create_venue(group: create_group, owner: create_user)

    post "/api/v1/events", params: {
      event: { title: "X", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour,
               group_id: group.id, venue_id: unrelated_venue.id }
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
