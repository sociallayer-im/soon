require "test_helper"

# The public browse/schedule listing (GET /events with filters) and the event
# ops the dashboard needs: pending-approval inbox, approve, check-in, venue
# conflict lookup.
class EventBrowseTest < ActionDispatch::IntegrationTest
  test "anonymous browse by group slug returns public events only" do
    owner = create_user
    group = create_group(owner: owner)
    published = create_event(group: group, owner: owner, status: "published")
    create_event(group: group, owner: owner, status: "draft")
    create_event(group: group, owner: owner, status: "published", visibility: "unlisted")

    get "/api/v1/events", params: { group_id: group.name }
    assert_response :success
    assert_equal [published.id], json_response["data"].map { |e| e["id"] }
    assert_not json_response["data"].first.key?("is_attending"), "anonymous listing has no viewer flags"
  end

  test "collection filter splits upcoming and past" do
    owner = create_user
    group = create_group(owner: owner)
    past = create_event(group: group, owner: owner, status: "published",
      start_time: 3.days.ago, end_time: 3.days.ago + 2.hours)
    upcoming = create_event(group: group, owner: owner, status: "published")

    get "/api/v1/events", params: { group_id: group.id, collection: "upcoming" }
    assert_equal [upcoming.id], json_response["data"].map { |e| e["id"] }

    get "/api/v1/events", params: { group_id: group.id, collection: "past" }
    assert_equal [past.id], json_response["data"].map { |e| e["id"] }
  end

  test "filters: search_title, tags, track, venue, pinned, skip_recurring" do
    owner = create_user
    group = create_group(owner: owner)
    track = create_track(group: group)
    venue = create_venue(group: group, owner: owner)
    a = create_event(group: group, owner: owner, status: "published", title: "Rust Workshop",
      tags: ["dev"], track_id: track.id, venue_id: venue.id, pinned: true)
    b = create_event(group: group, owner: owner, status: "published", title: "Yoga",
      recurring_id: "r1")

    get "/api/v1/events", params: { group_id: group.id, search_title: "rust" }
    assert_equal [a.id], json_response["data"].map { |e| e["id"] }

    get "/api/v1/events", params: { group_id: group.id, tags: ["dev"] }
    assert_equal [a.id], json_response["data"].map { |e| e["id"] }

    get "/api/v1/events", params: { group_id: group.id, track_id: track.id }
    assert_equal [a.id], json_response["data"].map { |e| e["id"] }

    get "/api/v1/events", params: { group_id: group.id, venue_id: venue.id }
    assert_equal [a.id], json_response["data"].map { |e| e["id"] }

    get "/api/v1/events", params: { group_id: group.id, pinned: "1" }
    assert_equal [a.id], json_response["data"].map { |e| e["id"] }

    get "/api/v1/events", params: { group_id: group.id, skip_recurring: "1" }
    assert_not_includes json_response["data"].map { |e| e["id"] }, b.id
  end

  test "date window filter honors the request timezone" do
    owner = create_user
    group = create_group(owner: owner)
    # 2026-08-01 02:00 UTC == 2026-07-31 22:00 in New York.
    event = create_event(group: group, owner: owner, status: "published",
      start_time: Time.utc(2026, 8, 1, 2), end_time: Time.utc(2026, 8, 1, 4))

    get "/api/v1/events", params: { group_id: group.id, start_date: "2026-07-31",
      end_date: "2026-07-31", timezone: "America/New_York" }
    assert_equal [event.id], json_response["data"].map { |e| e["id"] }

    get "/api/v1/events", params: { group_id: group.id, start_date: "2026-07-31",
      end_date: "2026-07-31" } # UTC window: event is on Aug 1
    assert_empty json_response["data"]
  end

  test "authenticated browse carries viewer flags" do
    owner = create_user
    viewer = create_user
    group = create_group(owner: owner)
    create_membership(user: viewer, group: group)
    attending = create_event(group: group, owner: owner, status: "published")
    starred = create_event(group: group, owner: owner, status: "published")
    create_participant(event: attending, user: viewer)
    Comment.create!(user: viewer, comment_type: "star", item_type: "Event", item_id: starred.id)

    get "/api/v1/events", params: { group_id: group.id }, headers: auth_headers(viewer)
    by_id = json_response["data"].index_by { |e| e["id"] }
    assert_equal true,  by_id[attending.id]["is_attending"]
    assert_equal false, by_id[attending.id]["is_starred"]
    assert_equal true,  by_id[starred.id]["is_starred"]
    assert_equal false, by_id[starred.id]["is_owner"]
  end

  test "pending_approval lists only managed groups and approve publishes" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group)
    pending = create_event(group: group, owner: member, status: "pending")

    other_owner = create_user
    other_group = create_group(owner: other_owner)
    create_event(group: other_group, owner: other_owner, status: "pending")

    get "/api/v1/events/pending_approval", headers: auth_headers(owner)
    assert_response :success
    assert_equal [pending.id], json_response["data"].map { |e| e["id"] }

    # The event's own author (plain member) cannot approve it.
    post "/api/v1/events/#{pending.id}/approve", headers: auth_headers(member)
    assert_response :forbidden

    post "/api/v1/events/#{pending.id}/approve", headers: auth_headers(owner)
    assert_response :success
    assert_equal "published", pending.reload.status
  end

  test "manager can check in a participant" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published")
    create_participant(event: event, user: attendee)

    post "/api/v1/events/#{event.id}/participants/check_in",
      params: { user_id: attendee.id }, headers: auth_headers(attendee)
    assert_response :forbidden, "attendees cannot check themselves in"

    post "/api/v1/events/#{event.id}/participants/check_in",
      params: { user_id: attendee.id }, headers: auth_headers(owner)
    assert_response :success
    assert_not_nil json_response["checked_in_at"]
    assert_not_nil Participant.find_by(event: event, user: attendee).checked_in_at
  end

  test "an RSVP is not a check-in — registered_at must not imply attendance at the door" do
    owner = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published")
    ticket = create_ticket(event: event)

    post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    assert_response :success

    participant = Participant.find_by(event: event, user: buyer)
    assert_not_nil participant.registered_at, "RSVP still records when they registered"
    assert_nil participant.checked_in_at, "registering must not mark them checked in"
  end

  test "venue conflict returns the clashing event and honors exclude_event_id" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)
    booked = create_event(group: group, owner: owner, status: "published", venue_id: venue.id,
      start_time: Time.utc(2026, 8, 1, 10), end_time: Time.utc(2026, 8, 1, 12))

    get "/api/v1/venues/#{venue.id}/conflict", params: {
      start_time: "2026-08-01 11:00", end_time: "2026-08-01 13:00"
    }, headers: auth_headers(owner)
    assert_response :success
    assert_equal booked.id, json_response["event"]["id"]

    get "/api/v1/venues/#{venue.id}/conflict", params: {
      start_time: "2026-08-01 11:00", end_time: "2026-08-01 13:00", exclude_event_id: booked.id
    }, headers: auth_headers(owner)
    assert_nil json_response["event"]

    get "/api/v1/venues/#{venue.id}/conflict", params: { start_time: "nope" }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
  end
end
