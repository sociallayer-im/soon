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

  # --- instance key singleton ------------------------------------------------

  test "create_singleton loses gracefully to an existing key" do
    FedInstanceKey.delete_all
    first = FedInstanceKey.current
    again = FedInstanceKey.create_singleton
    assert_equal first.id, again.id, "the unique guard must make the second insert read, not write"
    assert_equal 1, FedInstanceKey.count
  end
end
