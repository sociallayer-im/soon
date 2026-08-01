require "test_helper"

# Outbox pattern + delivery pipeline (design/FEDERATION_TEST_PLAN.md §2:
# OB atomicity, sweeper claiming, DL state machine against a stubbed
# transport, CB circuit breaker, audience expansion with governance filters).
class FederationDeliveryTest < ActionDispatch::IntegrationTest
  include FederationHelpers
  include ActiveJob::TestHelper

  setup do
    ENV["FEDERATION_ENABLED"] = "true"
    Rails.cache.clear
    @owner = create_user
    @group = create_group(owner: @owner)
    @remote, @key = create_fed_actor
    FedFollow.create!(local: @group, fed_actor: @remote, direction: "inbound",
                      state: "accepted", uri: "#{@remote.uri}#follows/1")
  end

  teardown { ENV.delete("FEDERATION_ENABLED") }

  def publish_event!(**attrs)
    event = create_event(group: @group, owner: @owner,
                         visibility: "public", status: "published", **attrs)
    Federation::OutboxService.publish_event(event, :create)
    event
  end

  # --- outbox writes ---------------------------------------------------------

  test "publishing an event enqueues one delivery per distinct inbox" do
    other, = create_fed_actor
    FedFollow.create!(local: @group, fed_actor: other, direction: "inbound",
                      state: "accepted", uri: "#{other.uri}#follows/1")
    same_domain_twin = FedActor.create!(
      uri: "https://#{@remote.domain}/users/bob", domain: @remote.domain,
      inbox_url: "https://#{@remote.domain}/users/bob/inbox",
      shared_inbox_url: @remote.shared_inbox_url, actor_type: "Person"
    )
    FedFollow.create!(local: @group, fed_actor: same_domain_twin, direction: "inbound",
                      state: "accepted", uri: "#{same_domain_twin.uri}#follows/1")

    assert_difference -> { FedDelivery.count } => 2 do # twin collapses into shared inbox (OB-4)
      publish_event!
    end
    payload = FedDelivery.last.payload
    assert_equal "Create", payload["type"]
    assert_equal "Event", payload["object"]["type"]
    assert_includes payload["to"], Federation::JsonLd::PUBLIC
  end

  test "business rollback leaves no delivery rows (OB-1)" do
    assert_no_difference -> { FedDelivery.count } do
      assert_raises(RuntimeError) do
        ActiveRecord::Base.transaction do
          publish_event!
          raise "boom"
        end
      end
    end
  end

  test "blocked and unavailable domains are filtered at enqueue, not delivery (BL-2/CB-1)" do
    FedDomainPolicy.create!(domain: @remote.domain, policy: "blocked")
    assert_no_difference(-> { FedDelivery.count }) { publish_event! }

    FedDomainPolicy.destroy_all
    FedDomainStat.for(@remote.domain).update!(unavailable_since: 10.days.ago.to_date)
    assert_no_difference(-> { FedDelivery.count }) { publish_event! }
  end

  test "no followers means no serialization work and no rows" do
    FedFollow.destroy_all
    assert_no_difference(-> { FedDelivery.count }) { publish_event! }
  end

  # --- sweeper ---------------------------------------------------------------

  test "sweeper claims due rows once and requeues crashed delivering rows (DL-5)" do
    publish_event!
    orphan = FedDelivery.create!(payload: {"type" => "Create"}, sender_type: "Group",
                                 sender_id: @group.id, inbox_url: "https://x.example/inbox",
                                 status: "delivering", updated_at: 30.minutes.ago)
    FedDelivery.where(id: orphan.id).update_all(updated_at: 30.minutes.ago)

    assert_enqueued_jobs 2, only: Federation::DeliveryJob do
      Federation::SweeperJob.perform_now
    end
    assert_equal "delivering", orphan.reload.status
    # second sweep with nothing new claims nothing
    assert_enqueued_jobs 0, only: Federation::DeliveryJob do
      Federation::SweeperJob.perform_now
    end
  end

  # --- delivery job against a stubbed transport ------------------------------

  def deliver_with_status(http_status, error: nil)
    publish_event!
    delivery = FedDelivery.last
    delivery.update!(status: "delivering")
    result = http_status && Federation::HttpClient::Result.new(status: http_status, headers: {}, body: "")
    stub = lambda { |*args, **kwargs|
      raise Federation::HttpClient::Error, error if error
      result
    }
    Federation::HttpClient.stub(:post, stub) do
      Federation::DeliveryJob.perform_now(delivery.id)
    end
    delivery.reload
  end

  test "202 marks delivered and records domain success (DL-1/OM-1)" do
    delivery = deliver_with_status(202)
    assert_equal "delivered", delivery.status
    stat = FedDomainStat.for(@remote.domain)
    assert_equal 1, stat.delivered_count
    assert_nil stat.unavailable_since
  end

  test "500 reschedules with backoff; 403 is permanent (DL-2/DL-3)" do
    retried = deliver_with_status(500)
    assert_equal "pending", retried.status
    assert retried.next_attempt_at > Time.current

    permanent = deliver_with_status(403)
    assert_equal "failed_permanent", permanent.status
  end

  test "transport error retries and marks the domain failing (DL-2/CB)" do
    delivery = deliver_with_status(nil, error: "connect timeout")
    assert_equal "pending", delivery.status
    stat = FedDomainStat.for(@remote.domain)
    assert_equal 1, stat.failed_count
    assert_equal Date.current, stat.unavailable_since
  end

  test "delivery POST carries a verifiable signature from the group actor" do
    publish_event!
    delivery = FedDelivery.last
    delivery.update!(status: "delivering")
    captured = nil
    stub = lambda { |url, body:, headers:|
      captured = {url: url, body: body, headers: headers}
      Federation::HttpClient::Result.new(status: 202, headers: {}, body: "")
    }
    Federation::HttpClient.stub(:post, stub) do
      Federation::DeliveryJob.perform_now(delivery.id)
    end

    assert captured, "no HTTP call captured"
    # verify with the group's public key, exactly as the remote will
    assert Federation::HttpSignature.verify!(
      method: :post, path: URI.parse(captured[:url]).path,
      headers: captured[:headers].transform_keys(&:downcase),
      body: captured[:body],
      public_key_pem: @group.reload.fed_public_key
    )
    params = Federation::HttpSignature.parse_signature_header(captured[:headers]["Signature"])
    assert_equal Federation::Urls.key_id(@group), params["keyId"]
  end

  # --- circuit breaker semantics (CB-2/CB-3) ---------------------------------

  test "a success resets unavailable_since; legit inbound contact does too" do
    stat = FedDomainStat.for(@remote.domain)
    stat.update!(unavailable_since: 3.days.ago.to_date)
    FedDomainStat.record_delivery!(@remote.domain, success: true)
    assert_nil stat.reload.unavailable_since

    stat.update!(unavailable_since: 3.days.ago.to_date)
    FedDomainStat.record_inbound!(@remote.domain)
    assert_nil stat.reload.unavailable_since
    refute FedDomainStat.unavailable?(@remote.domain)
  end
end
