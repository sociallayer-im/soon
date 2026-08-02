require "test_helper"

# Phase 4 — the outbound direction: we are the follower and the participant.
# Only the origin instance may approve, so everything stays pending until its
# Accept arrives (design/FEDERATION_PLAN.md §2.7).
class FederationOutboundTest < ActionDispatch::IntegrationTest
  include FederationHelpers
  include ActiveJob::TestHelper

  setup do
    ENV["FEDERATION_ENABLED"] = "true"
    Federation::RateLimiter.reset!
    @user = create_user
    @remote, @key = create_fed_actor(actor_type: "Group")
  end

  teardown { ENV.delete("FEDERATION_ENABLED") }

  def remote_event_json(**over)
    {
      "type" => "Event",
      "id" => "#{@remote.uri}/events/#{SecureRandom.hex(4)}",
      "name" => "Remote Meetup",
      "content" => "<p>hi</p><script>evil()</script>",
      "summary" => "Aug 9 - GMT+02:00 - Galata",
      "startTime" => 3.days.from_now.utc.iso8601,
      "endTime" => (3.days.from_now + 2.hours).utc.iso8601,
      "timezone" => "Europe/Istanbul",
      "status" => "CONFIRMED",
      "joinMode" => "free",
      "maximumAttendeeCapacity" => 30,
      "participantCount" => 4,
      "location" => {"type" => "Place", "name" => "Galata Tower",
                     "address" => {"type" => "PostalAddress", "streetAddress" => "Bereketzade"},
                     "latitude" => 41.0256, "longitude" => 28.9744},
      "attachment" => [{"type" => "Image", "name" => "Banner", "url" => "https://cdn.example/b.png"}],
      "tag" => [{"type" => "Hashtag", "name" => "#fediverse"}],
      "url" => "#{@remote.uri}/e/1"
    }.merge(over)
  end

  def deliver(activity)
    perform_enqueued_jobs { post_signed_activity(@remote, @key, activity) }
  end

  def create_activity(object)
    {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}/act/#{SecureRandom.hex(4)}",
     "type" => "Create", "actor" => @remote.uri, "object" => object}
  end

  # --- mirroring remote events ----------------------------------------------

  test "Create(Event) from a remote actor is mirrored with its fields intact" do
    obj = remote_event_json
    assert_difference -> { FedEvent.count } => 1 do
      deliver(create_activity(obj))
    end
    assert_response :accepted

    e = FedEvent.find_by(uri: obj["id"])
    assert_equal "Remote Meetup", e.title
    assert_equal "Europe/Istanbul", e.timezone
    assert_equal "free", e.join_mode
    assert_equal 30, e.max_participant
    assert_equal 4, e.participant_count
    assert_equal "Galata Tower", e.location_name
    assert_equal "Bereketzade", e.address
    assert_in_delta 41.0256, e.latitude.to_f, 0.0001
    assert_in_delta 28.9744, e.longitude.to_f, 0.0001
    assert_equal ["fediverse"], e.tags
    assert_equal "https://cdn.example/b.png", e.image_url
    refute_includes e.content, "<script>", "remote HTML must be sanitized"
  end

  test "an event whose id is on another host than its sender is refused" do
    obj = remote_event_json("id" => "https://elsewhere.example/events/1")
    assert_no_difference -> { FedEvent.count } do
      deliver(create_activity(obj))
    end
    assert_response :accepted
  end

  test "malformed geo and capacity degrade instead of dropping the event" do
    obj = remote_event_json(
      "location" => {"type" => "Place", "name" => "Somewhere",
                     "latitude" => "41.02", "longitude" => 999},
      "maximumAttendeeCapacity" => -5, "joinMode" => "nonsense"
    )
    deliver(create_activity(obj))
    e = FedEvent.find_by(uri: obj["id"])
    assert e, "event should still be mirrored"
    assert_nil e.latitude, "a string latitude is dropped, not fatal"
    assert_nil e.longitude, "an out-of-range longitude is dropped"
    assert_nil e.max_participant
    assert_equal "free", e.join_mode, "unknown joinMode degrades to free"
  end

  test "Update refreshes the mirror and Delete retires it, but only from the origin" do
    obj = remote_event_json
    deliver(create_activity(obj))
    e = FedEvent.find_by(uri: obj["id"])

    upd = {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}/act/u1",
           "type" => "Update", "actor" => @remote.uri,
           "object" => obj.merge("name" => "Remote Meetup (moved)", "status" => "CANCELLED")}
    deliver(upd)
    assert_equal "Remote Meetup (moved)", e.reload.title
    assert_equal "CANCELLED", e.status

    # a different instance may not delete it
    other, other_key = create_fed_actor
    del = {"@context" => Federation::JsonLd::AS, "id" => "#{other.uri}/act/d1",
           "type" => "Delete", "actor" => other.uri, "object" => obj["id"]}
    perform_enqueued_jobs { post_signed_activity(other, other_key, del) }
    assert FedEvent.exists?(uri: obj["id"]), "only the origin may retire an event"
  end

  # --- outbound follow -------------------------------------------------------

  test "following a remote actor queues a Follow and stays pending until Accept" do
    follow = nil
    assert_difference -> { FedDelivery.count } => 1 do
      follow = Federation::OutboxService.follow(@user, @remote)
    end
    assert_equal "pending", follow.state
    assert_equal "outbound", follow.direction

    payload = FedDelivery.last.payload
    assert_equal "Follow", payload["type"]
    assert_equal follow.uri, payload["id"]
    assert_equal Federation::Urls.actor_url(@user), payload["actor"]
    assert_equal @remote.uri, payload["object"]

    accept = {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}/accept/1",
              "type" => "Accept", "actor" => @remote.uri, "object" => payload}
    deliver(accept)
    assert_equal "accepted", follow.reload.state
  end

  test "Accept naming an unknown activity is ignored" do
    accept = {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}/accept/x",
              "type" => "Accept", "actor" => @remote.uri,
              "object" => "https://app.sola.day/follows/does-not-exist"}
    deliver(accept)
    assert_response :accepted
  end

  test "unfollow sends an Undo with the Follow inlined and drops the edge" do
    Federation::OutboxService.follow(@user, @remote)
    assert_difference -> { FedDelivery.count } => 1, -> { FedFollow.count } => -1 do
      Federation::OutboxService.unfollow(@user, @remote)
    end
    payload = FedDelivery.last.payload
    assert_equal "Undo", payload["type"]
    assert_equal "Follow", payload["object"]["type"], "Undo must inline the Follow"
    assert_equal @remote.uri, payload["object"]["object"]
  end

  # --- outbound join ---------------------------------------------------------

  def mirrored_event(**over)
    obj = remote_event_json(**over)
    deliver(create_activity(obj))
    FedEvent.find_by(uri: obj["id"])
  end

  test "joining a remote event stays pending until the origin Accepts" do
    e = mirrored_event
    part = nil
    assert_difference -> { FedDelivery.count } => 1 do
      part = Federation::OutboxService.join(@user, e, message: "coming")
    end
    assert_equal "pending", part.status

    payload = FedDelivery.last.payload
    assert_equal "Join", payload["type"]
    assert_equal e.uri, payload["object"]
    assert_equal "coming", payload["participationMessage"]
    assert_equal e.origin_inbox_url, FedDelivery.last.inbox_url

    accept = {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}/accept/j1",
              "type" => "Accept", "actor" => @remote.uri, "object" => payload}
    deliver(accept)
    assert_equal "attending", part.reload.status
  end

  test "a Reject from the origin marks the participation rejected" do
    e = mirrored_event
    part = Federation::OutboxService.join(@user, e)
    reject = {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}/reject/j1",
              "type" => "Reject", "actor" => @remote.uri, "object" => FedDelivery.last.payload,
              "summary" => "event is full"}
    deliver(reject)
    assert_equal "rejected", part.reload.status
  end

  test "an instance that does not own the event cannot accept a join for it" do
    e = mirrored_event
    part = Federation::OutboxService.join(@user, e)
    join_payload = FedDelivery.last.payload

    other, other_key = create_fed_actor
    accept = {"@context" => Federation::JsonLd::AS, "id" => "#{other.uri}/accept/x",
              "type" => "Accept", "actor" => other.uri, "object" => join_payload}
    perform_enqueued_jobs { post_signed_activity(other, other_key, accept) }
    assert_equal "pending", part.reload.status, "only the origin may approve"
  end

  test "leaving sends a Leave and cancels locally" do
    e = mirrored_event
    Federation::OutboxService.join(@user, e)
    part = Federation::OutboxService.leave(@user, e)
    assert_equal "cancelled", part.status
    assert_equal "Leave", FedDelivery.last.payload["type"]
  end

  test "external and cancelled events are not joinable" do
    refute mirrored_event("joinMode" => "external").joinable?
    refute mirrored_event("status" => "CANCELLED").joinable?
    assert mirrored_event.joinable?
  end

  # --- user-facing API -------------------------------------------------------

  test "the discovery API lists mirrored events and reports my status" do
    e = mirrored_event
    get "/api/v1/federation/events"
    assert_response :success
    row = json_response.find { |r| r["uri"] == e.uri }
    assert_equal "Remote Meetup", row["title"]
    assert_equal @remote.acct, row.dig("origin", "acct")
    assert_equal 41.0256, row.dig("location", "latitude").to_f

    Federation::OutboxService.join(@user, e)
    get "/api/v1/federation/events/#{e.id}", headers: auth_headers(@user)
    assert_equal "pending", json_response["my_status"]
  end

  test "the API refuses to join an external event and requires a handle" do
    ext = mirrored_event("joinMode" => "external")
    post "/api/v1/federation/events/#{ext.id}/join", headers: auth_headers(@user)
    assert_response :unprocessable_entity

    e = mirrored_event
    @user.update!(name: nil)
    post "/api/v1/federation/events/#{e.id}/join", headers: auth_headers(@user)
    assert_response :unprocessable_entity
  end

  test "federation API 404s while the flag is off" do
    ENV.delete("FEDERATION_ENABLED")
    get "/api/v1/federation/events"
    assert_response :not_found
  end
  # --- retiring things -------------------------------------------------------

  test "deleting a group tells its followers, before the row disappears" do
    group = create_group(owner: @user)
    FedFollow.create!(local: group, fed_actor: @remote, direction: "inbound",
                      state: "accepted", uri: "#{@remote.uri}#f/1")
    event = create_event(group: group, owner: @user, visibility: "public", status: "published")

    assert_difference -> { FedDelivery.count } => 2 do
      delete "/api/v1/groups/#{group.id}", headers: auth_headers(@user)
    end
    assert_response :no_content

    types = FedDelivery.order(:created_at).last(2).map { |d| d.payload["type"] }
    assert_equal %w[Delete Delete], types
    payloads = FedDelivery.order(:created_at).last(2).map(&:payload)
    assert payloads.any? { |p| p.dig("object", "type") == "Tombstone" },
           "the event is retired with a Tombstone"
    assert payloads.any? { |p| p["object"].is_a?(String) && p["object"].include?("/groups/") },
           "the actor itself is deleted too"
    refute Group.exists?(group.id)
  end

  test "a remote actor deleting itself purges what we mirrored for it" do
    obj = remote_event_json
    deliver(create_activity(obj))
    assert_equal 1, FedEvent.where(fed_actor_id: @remote.id).count

    del = {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}#delete",
           "type" => "Delete", "actor" => @remote.uri, "object" => @remote.uri}
    deliver(del)
    assert_response :accepted
    refute FedActor.exists?(@remote.id), "the actor is gone"
    assert_equal 0, FedEvent.where(uri: obj["id"]).count, "and so is everything it published"
  end

  test "one actor cannot delete another" do
    obj = remote_event_json
    deliver(create_activity(obj))
    other, other_key = create_fed_actor

    del = {"@context" => Federation::JsonLd::AS, "id" => "#{other.uri}#delete",
           "type" => "Delete", "actor" => other.uri, "object" => @remote.uri}
    perform_enqueued_jobs { post_signed_activity(other, other_key, del) }
    assert FedActor.exists?(@remote.id), "only an actor may delete itself"
    assert_equal 1, FedEvent.where(uri: obj["id"]).count
  end
end
