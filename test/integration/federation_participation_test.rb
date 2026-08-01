require "test_helper"

# Phase 3: cross-instance participation and comments
# (design/FEDERATION_TEST_PLAN.md §4 semantics table, §3.3 field handling).
class FederationParticipationTest < ActionDispatch::IntegrationTest
  include FederationHelpers
  include ActiveJob::TestHelper

  setup do
    ENV["FEDERATION_ENABLED"] = "true"
    Federation::RateLimiter.reset!
    @owner = create_user
    @group = create_group(owner: @owner)
    @remote, @key = create_fed_actor
  end

  teardown { ENV.delete("FEDERATION_ENABLED") }

  def public_event(**attrs)
    create_event(group: @group, owner: @owner, visibility: "public", status: "published",
                 start_time: 2.days.from_now, end_time: 3.days.from_now, **attrs)
  end

  def join_activity(event, id: nil, message: nil)
    {
      "@context" => Federation::JsonLd::AS,
      "id" => id || "#{@remote.uri}/join/#{SecureRandom.hex(4)}",
      "type" => "Join",
      "actor" => @remote.uri,
      "object" => Federation::Urls.event_url(event),
      "participationMessage" => message
    }.compact
  end

  def send_join(event, **opts)
    perform_enqueued_jobs { post_signed_activity(@remote, @key, join_activity(event, **opts)) }
  end

  # --- free join: seated + Accept (Mobilizon free semantics) ------------------

  test "free event seats the remote participant and sends Accept echoing the Join" do
    event = public_event
    activity = join_activity(event, message: "see you there")
    assert_difference -> { Participant.count } => 1, -> { FedDelivery.count } => 1 do
      perform_enqueued_jobs { post_signed_activity(@remote, @key, activity) }
    end
    assert_response :accepted

    participant = Participant.last
    assert_equal "attending", participant.status
    assert_equal @remote.id, participant.fed_actor_id
    assert_nil participant.user_id
    assert_equal activity["id"], participant.fed_join_uri
    assert_equal "see you there", participant.message
    assert_equal 1, event.reload.participant_count

    accept = FedDelivery.last.payload
    assert_equal "Accept", accept["type"]
    assert_equal activity["id"], accept["object"]["id"], "Accept must inline the original Join"
    assert_equal Federation::Urls.actor_url(@group), accept["attributedTo"]
    assert_match %r{/accept/join/}, accept["id"]
  end

  test "duplicate Join does not double-seat" do
    event = public_event
    send_join(event)
    assert_no_difference -> { Participant.count } do
      send_join(event)
    end
    assert_equal 1, event.reload.participant_count
  end

  # --- approval required (restricted) ----------------------------------------

  test "require_approval holds the remote participant pending, no Accept yet" do
    event = public_event(require_approval: true)
    assert_difference -> { Participant.count } => 1, -> { FedDelivery.count } => 0 do
      send_join(event)
    end
    participant = Participant.last
    assert_equal "pending", participant.status
    assert_equal 0, event.reload.participant_count
  end

  test "manager approving a remote participant sends Accept through the existing UI path" do
    event = public_event(require_approval: true)
    send_join(event)
    participant = Participant.last

    assert_difference -> { FedDelivery.count } => 1 do
      post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve",
           headers: auth_headers(@owner)
    end
    assert_response :success
    assert_equal "attending", participant.reload.status
    assert_equal "Accept", FedDelivery.last.payload["type"]
  end

  test "manager rejecting a remote participant sends Reject" do
    event = public_event(require_approval: true)
    send_join(event)
    participant = Participant.last

    assert_difference -> { FedDelivery.count } => 1 do
      post "/api/v1/events/#{event.id}/participants/#{participant.id}/reject",
           headers: auth_headers(@owner)
    end
    assert_response :success
    assert_equal "declined", participant.reload.status
    assert_equal "Reject", FedDelivery.last.payload["type"]
  end

  # --- capacity and eligibility ----------------------------------------------

  test "a full event rejects the Join and seats nobody (no overselling)" do
    event = public_event(max_participant: 1)
    event.update!(participant_count: 1)
    assert_no_difference -> { Participant.count } do
      send_join(event)
    end
    assert_equal "Reject", FedDelivery.last.payload["type"]
    assert_equal 1, event.reload.participant_count
  end

  test "ticketed events are external: Join rejected, buyer sent back to the source" do
    event = public_event
    Ticket.create!(event: event, group: @group, title: "GA", status: "normal")
    assert_no_difference(-> { Participant.count }) { send_join(event) }
    assert_equal "Reject", FedDelivery.last.payload["type"]
  end

  test "draft and private events are not joinable" do
    [public_event(status: "draft"), public_event(visibility: "private")].each do |event|
      assert_no_difference(-> { Participant.count }) { send_join(event) }
    end
  end

  # --- leave ------------------------------------------------------------------

  test "Leave cancels the participation and frees the seat" do
    event = public_event
    send_join(event)
    assert_equal 1, event.reload.participant_count

    leave = {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}/leave/1",
             "type" => "Leave", "actor" => @remote.uri,
             "object" => Federation::Urls.event_url(event)}
    perform_enqueued_jobs { post_signed_activity(@remote, @key, leave) }
    assert_response :accepted
    assert_equal "cancelled", Participant.last.status
    assert_equal 0, event.reload.participant_count
  end

  test "Leave without a participation is a silent no-op" do
    event = public_event
    leave = {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}/leave/2",
             "type" => "Leave", "actor" => @remote.uri,
             "object" => Federation::Urls.event_url(event)}
    perform_enqueued_jobs { post_signed_activity(@remote, @key, leave) }
    assert_response :accepted
    assert_equal 0, Participant.count
  end

  # --- comments ---------------------------------------------------------------

  test "Note inReplyTo an event becomes a sanitized event comment" do
    event = public_event
    note = {
      "@context" => Federation::JsonLd::AS,
      "id" => "#{@remote.uri}/statuses/1/activity", "type" => "Create", "actor" => @remote.uri,
      "object" => {"type" => "Note", "id" => "#{@remote.uri}/statuses/1",
                   "attributedTo" => @remote.uri,
                   "inReplyTo" => Federation::Urls.event_url(event),
                   "content" => "<p>nice</p><script>evil()</script>"}
    }
    assert_difference -> { Comment.count } => 1 do
      perform_enqueued_jobs { post_signed_activity(@remote, @key, note) }
    end
    comment = Comment.last
    assert_equal event.id, comment.item_id
    assert_equal @remote.id, comment.fed_actor_id
    refute_includes comment.content, "<script>"
    assert_includes comment.content, "nice"

    # replay is idempotent
    assert_no_difference -> { Comment.count } do
      perform_enqueued_jobs { post_signed_activity(@remote, @key, note) }
    end
  end

  test "Note replying to nothing local is ignored" do
    note = {
      "@context" => Federation::JsonLd::AS,
      "id" => "#{@remote.uri}/statuses/9/activity", "type" => "Create", "actor" => @remote.uri,
      "object" => {"type" => "Note", "id" => "#{@remote.uri}/statuses/9",
                   "inReplyTo" => "https://elsewhere.example/notes/1", "content" => "hi"}
    }
    assert_no_difference -> { Comment.count } do
      perform_enqueued_jobs { post_signed_activity(@remote, @key, note) }
    end
    assert_response :accepted
  end
end
