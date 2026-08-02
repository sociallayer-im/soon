require "test_helper"

# Regressions for the hardening pass (review 2026-08-02): inbound failure
# recovery, outbox atomicity, delivery id uniqueness, instance-key singleton.
class FederationHardeningTest < ActionDispatch::IntegrationTest
  include FederationHelpers
  include ActiveJob::TestHelper

  setup do
    ENV["FEDERATION_ENABLED"] = "true"
    Federation::RateLimiter.reset!
    @remote, @key = create_fed_actor
  end

  teardown { ENV.delete("FEDERATION_ENABLED") }

  # --- inbound state machine -------------------------------------------------

  test "an activity is 'received' at the inbox and 'processed' only after the job ran" do
    follow = follow_activity(@remote, create_group)
    post_signed_activity(@remote, @key, follow) # jobs NOT performed
    assert_response :accepted
    assert_equal "received", FedInboundActivity.find_by(uri: follow["id"]).status

    perform_enqueued_jobs
    assert_equal "processed", FedInboundActivity.find_by(uri: follow["id"]).status
  end

  test "a processing crash marks the ledger failed, and a redelivery re-runs it" do
    group = create_group
    follow = follow_activity(@remote, group)
    post_signed_activity(@remote, @key, follow)
    assert_response :accepted

    # drive the job to its terminal failure (retries exhausted) — retry_on
    # counts per-exception-class executions, not the plain counter
    job = Federation::InboundJob.new(@remote.id, follow)
    job.exception_executions = {"[StandardError]" => 2}
    Federation::InboxService.stub(:process, ->(*) { raise "boom" }) { job.perform_now }
    assert_equal "failed", FedInboundActivity.find_by(uri: follow["id"]).status

    # the remote redelivers the same id: not a duplicate — it re-runs and succeeds
    perform_enqueued_jobs { post_signed_activity(@remote, @key, follow) }
    assert_response :accepted
    assert_equal "processed", FedInboundActivity.find_by(uri: follow["id"]).status
    assert FedFollow.exists?(uri: follow["id"]), "the retried Follow must actually process"
  end

  test "an unhandled type lands as ignored, not processed" do
    activity = {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}/act/#{SecureRandom.hex(4)}",
                "type" => "Arrive", "actor" => @remote.uri, "object" => "somewhere"}
    perform_enqueued_jobs { post_signed_activity(@remote, @key, activity) }
    assert_response :accepted
    assert_equal "ignored", FedInboundActivity.find_by(uri: activity["id"]).status
  end

  # --- outbox atomicity ------------------------------------------------------

  test "an outbox write failure rolls the event update back (no local/remote divergence)" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "public")
    before = event.title

    # In the test env the 500 surfaces as the raw exception; what matters is
    # the rollback.
    assert_raises(RuntimeError) do
      Federation::OutboxService.stub(:publish_event, ->(*) { raise "outbox down" }) do
        patch "/api/v1/events/#{event.id}", params: {event: {title: "Diverged"}},
          headers: auth_headers(owner)
      end
    end
    assert_equal before, event.reload.title, "a failed outbox write must roll the update back"
  end

  test "delivery fan-out is all-or-nothing" do
    group = create_group
    payload = {"type" => "Create", "id" => "x"}
    assert_no_difference "FedDelivery.count" do
      assert_raises(ActiveRecord::RecordInvalid) {
        Federation::OutboxService.enqueue(payload, sender: group,
          inboxes: ["https://ok.example/inbox", nil, "https://also-ok.example/inbox"])
      }
    end
  end

  # --- activity id uniqueness ------------------------------------------------

  test "two publishes in the same second carry distinct activity ids" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "public")
    FedFollow.create!(local: group, fed_actor: @remote, direction: "inbound",
                      state: "accepted", uri: "#{@remote.uri}#f1")

    Federation::OutboxService.publish_event(event, :update)
    Federation::OutboxService.publish_event(event, :update)
    ids = FedDelivery.order(:created_at).last(2).map { |d| d.payload["id"] }
    assert_equal 2, ids.uniq.size, "same-second updates must not share an activity id"
  end

  # --- retraction ------------------------------------------------------------

  def followed_public_event
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "public")
    FedFollow.create!(local: group, fed_actor: @remote, direction: "inbound",
                      state: "accepted", uri: "#{@remote.uri}#f-#{SecureRandom.hex(3)}")
    [owner, event]
  end

  test "flipping a federated event to private sends a Delete, not silence" do
    owner, event = followed_public_event
    assert_difference "FedDelivery.count", 1 do
      patch "/api/v1/events/#{event.id}", params: {event: {visibility: "private"}},
        headers: auth_headers(owner)
    end
    assert_response :success
    payload = FedDelivery.last.payload
    assert_equal "Delete", payload["type"]
    assert_equal "Tombstone", payload["object"]["type"]
  end

  test "removing a federated comment sends a Delete for its Note" do
    owner, event = followed_public_event
    comment = nil
    assert_difference "FedDelivery.count", 1 do # the Create
      post "/api/v1/comments", params: {comment: {item_type: "Event", item_id: event.id,
        comment_type: "comment", content: "hello fediverse"}}, headers: auth_headers(owner)
      assert_response :created
      comment = Comment.last
    end
    assert_difference "FedDelivery.count", 1 do # the Delete
      post "/api/v1/comments/#{comment.id}/remove", headers: auth_headers(owner)
      assert_response :success
    end
    payload = FedDelivery.last.payload
    assert_equal "Delete", payload["type"]
    assert_includes payload["object"]["id"], "/comments/#{comment.id}"
  end

  # --- remote mirror integrity -----------------------------------------------

  def remote_event(actor, **over)
    {
      "type" => "Event", "id" => "#{actor.uri}/events/#{SecureRandom.hex(4)}",
      "name" => "Meetup", "startTime" => 2.days.from_now.utc.iso8601,
      "attributedTo" => actor.uri,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }.merge(over)
  end

  test "a same-host actor cannot take over another actor's mirrored event" do
    victim, _vkey = create_fed_actor(uri: "https://shared.example/users/victim")
    attacker, _akey = create_fed_actor(uri: "https://shared.example/users/attacker")
    obj = remote_event(victim)
    original = Federation::RemoteEventService.upsert(obj, victim)
    assert original

    hijack = obj.merge("name" => "Hijacked", "attributedTo" => attacker.uri)
    assert_nil Federation::RemoteEventService.upsert(hijack, attacker)
    # even claiming the victim's attribution fails on the ownership check
    hijack2 = obj.merge("name" => "Hijacked", "attributedTo" => victim.uri)
    assert_nil Federation::RemoteEventService.upsert(hijack2, attacker)
    assert_equal "Meetup", original.reload.title
  end

  test "an event addressed to followers-only is not mirrored" do
    obj = remote_event(@remote, "to" => ["#{@remote.uri}/followers"], "cc" => [])
    assert_nil Federation::RemoteEventService.upsert(obj, @remote)
    # explicit Public in cc is enough
    pub = remote_event(@remote, "to" => ["#{@remote.uri}/followers"],
                                "cc" => ["https://www.w3.org/ns/activitystreams#Public"])
    assert Federation::RemoteEventService.upsert(pub, @remote)
  end

  test "an older Update cannot roll back a newer state, nor resurrect a Delete" do
    obj = remote_event(@remote, "name" => "v1", "updated" => 2.hours.ago.utc.iso8601)
    event = Federation::RemoteEventService.upsert(obj, @remote)
    Federation::RemoteEventService.upsert(
      obj.merge("name" => "v2", "updated" => 1.hour.ago.utc.iso8601), @remote)
    assert_equal "v2", event.reload.title

    # delayed retry of v1 arrives after v2
    Federation::RemoteEventService.upsert(
      obj.merge("name" => "v1", "updated" => 2.hours.ago.utc.iso8601), @remote)
    assert_equal "v2", event.reload.title, "older update must not roll back"

    # tombstone, then an old Update tries to revive
    event.update!(status: "CANCELLED", remote_updated_at: Time.current)
    Federation::RemoteEventService.upsert(
      obj.merge("name" => "revived", "updated" => 30.minutes.ago.utc.iso8601), @remote)
    assert_equal "CANCELLED", event.reload.status, "a delete is a version barrier"
  end

  test "a remote Note aimed at a private local event is ignored" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, visibility: "private", status: "published")
    note = {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}/note/1",
            "type" => "Create", "actor" => @remote.uri,
            "object" => {"type" => "Note", "id" => "#{@remote.uri}/n/1",
                         "inReplyTo" => Federation::Urls.event_url(event),
                         "content" => "probing"}}
    assert_no_difference "Comment.count" do
      perform_enqueued_jobs { post_signed_activity(@remote, @key, note) }
    end
  end

  # --- block coverage & kill switch ------------------------------------------

  test "blocking an actor hides its already-mirrored events from the public API" do
    obj = remote_event(@remote)
    event = Federation::RemoteEventService.upsert(obj, @remote)

    get "/api/v1/federation/events"
    assert_response :success
    assert_includes response.parsed_body.map { |e| e["uri"] }, event.uri

    @remote.update!(blocked_at: Time.current)
    get "/api/v1/federation/events"
    assert_equal [], response.parsed_body.map { |e| e["uri"] }
    get "/api/v1/federation/events/#{event.id}"
    assert_response :not_found
  end

  test "a domain blocked after enqueue suppresses the claimed delivery at send time" do
    d = FedDelivery.create!(payload: {"type" => "Create", "id" => "x"},
                            sender_type: "instance", sender_id: nil,
                            inbox_url: "https://#{@remote.domain}/inbox", status: "delivering")
    FedDomainPolicy.create!(domain: @remote.domain, policy: "blocked")
    Federation::DeliveryJob.perform_now(d.id)
    assert_equal "suppressed", d.reload.status
  end

  test "the kill switch parks a claimed delivery instead of sending" do
    d = FedDelivery.create!(payload: {"type" => "Create", "id" => "x"},
                            sender_type: "instance", sender_id: nil,
                            inbox_url: "https://#{@remote.domain}/inbox", status: "delivering")
    ENV.delete("FEDERATION_ENABLED")
    Federation::DeliveryJob.perform_now(d.id)
    assert_equal "pending", d.reload.status
    assert d.next_attempt_at > Time.current
  ensure
    ENV["FEDERATION_ENABLED"] = "true"
  end

  # --- instance key singleton ------------------------------------------------

  test "create_singleton loses gracefully to an existing key" do
    FedInstanceKey.delete_all
    first = FedInstanceKey.current
    again = FedInstanceKey.create_singleton
    assert_equal first.id, again.id, "the unique guard must make the second insert read, not write"
    assert_equal 1, FedInstanceKey.count
  end
end
