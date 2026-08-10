require "test_helper"

# INTEROP §10.3: follow reconciliation. The drift being repaired: our
# FedFollow says accepted, the peer's follower list says nothing, and every
# layer reports success while content silently never arrives.
class FederationReconciliationTest < ActionDispatch::IntegrationTest
  include FederationHelpers
  include ActiveJob::TestHelper

  SVC = Federation::FollowReconciliationService

  setup do
    ENV["FEDERATION_ENABLED"] = "true"
    Federation::RateLimiter.reset!
    Federation::ActorFetchService.reset_failures!
  end

  teardown { ENV.delete("FEDERATION_ENABLED") }

  def outbound_follow(user, actor, state: "accepted", confirmed_at: nil, created_at: nil, **attrs)
    f = FedFollow.create!(local: user, fed_actor: actor, direction: "outbound",
                          state: state, uri: "https://sola.seven.fan/follows/#{SecureRandom.uuid}",
                          last_confirmed_at: confirmed_at, **attrs)
    f.update_column(:created_at, created_at) if created_at
    f
  end

  def stub_get(responses, &block)
    fetcher = lambda { |uri, headers: nil|
      resp = responses[uri] or raise Federation::HttpClient::Error, "no stub for #{uri}"
      resp.is_a?(Exception) ? raise(resp) : resp
    }
    Federation::HttpClient.stub(:get, fetcher, &block)
  end

  def ap_result(doc, status: 200)
    Federation::HttpClient::Result.new(
      status: status, headers: {"content-type" => "application/activity+json"},
      body: doc.is_a?(String) ? doc : JSON.generate(doc)
    )
  end

  def remote_actor_doc(uri, key, extra = {})
    {
      "@context" => [Federation::JsonLd::AS, Federation::JsonLd::SECURITY],
      "id" => uri, "type" => "Person", "preferredUsername" => "peer",
      "inbox" => "#{uri}/inbox",
      "publicKey" => {"id" => "#{uri}#main-key", "owner" => uri,
                      "publicKeyPem" => key.public_key.to_pem}
    }.merge(extra)
  end

  # --- confirmation stamping ---------------------------------------------------

  test "an inbound Accept stamps last_confirmed_at and resets the probe counter" do
    actor, key = create_fed_actor
    user = create_user(name: "ru#{unique_suffix}")
    follow = outbound_follow(user, actor, state: "pending",
                             probed_at: 2.days.ago, probe_count: 2)
    accept = {"@context" => Federation::JsonLd::AS, "id" => "#{actor.uri}#accepts/1",
              "type" => "Accept", "actor" => actor.uri, "object" => follow.uri}
    perform_enqueued_jobs { post_signed_activity(actor, key, accept) }

    follow.reload
    assert_equal "accepted", follow.state
    assert_not_nil follow.last_confirmed_at
    assert_equal 0, follow.probe_count
  end

  # --- probing -----------------------------------------------------------------

  test "a stale accepted follow is probed with the ORIGINAL activity id" do
    actor, = create_fed_actor # last_fetched_at now → no liveness fetch needed
    user = create_user(name: "ru#{unique_suffix}")
    follow = outbound_follow(user, actor, confirmed_at: 8.days.ago)

    assert_difference "FedDelivery.count", 1 do
      SVC.run
    end
    follow.reload
    assert_equal 1, follow.probe_count
    assert_not_nil follow.probed_at
    probe = FedDelivery.order(:created_at).last
    assert_equal "Follow", probe.payload["type"]
    assert_equal follow.uri, probe.payload["id"],
                 "the probe must reuse the original id so the peer dedupes and re-Accepts"
    assert_equal actor.delivery_inbox_url, probe.inbox_url
  end

  test "a recently confirmed follow is left alone" do
    actor, = create_fed_actor
    user = create_user(name: "ru#{unique_suffix}")
    outbound_follow(user, actor, confirmed_at: 1.day.ago)
    assert_no_difference "FedDelivery.count" do
      SVC.run
    end
  end

  test "a probed follow is not re-probed inside the probe interval" do
    actor, = create_fed_actor
    user = create_user(name: "ru#{unique_suffix}")
    outbound_follow(user, actor, confirmed_at: 8.days.ago,
                    probed_at: 2.hours.ago, probe_count: 1)
    assert_no_difference "FedDelivery.count" do
      SVC.run
    end
  end

  test "a long-pending follow (lost Accept) is also probed" do
    actor, = create_fed_actor
    user = create_user(name: "ru#{unique_suffix}")
    follow = outbound_follow(user, actor, state: "pending", created_at: 8.days.ago)
    assert_difference "FedDelivery.count", 1 do
      SVC.run
    end
    assert_equal 1, follow.reload.probe_count
  end

  # --- lapsing -----------------------------------------------------------------

  test "probe exhaustion marks the edge lapsed instead of keeping it silently" do
    actor, = create_fed_actor
    user = create_user(name: "ru#{unique_suffix}")
    follow = outbound_follow(user, actor, confirmed_at: 30.days.ago,
                             probed_at: 2.days.ago, probe_count: SVC::MAX_PROBES)
    assert_no_difference "FedDelivery.count" do
      SVC.run
    end
    assert_equal "lapsed", follow.reload.state
  end

  test "a late Accept revives even a lapsed edge" do
    actor, key = create_fed_actor
    user = create_user(name: "ru#{unique_suffix}")
    follow = outbound_follow(user, actor, state: "lapsed",
                             probed_at: 3.days.ago, probe_count: SVC::MAX_PROBES)
    accept = {"@context" => Federation::JsonLd::AS, "id" => "#{actor.uri}#accepts/2",
              "type" => "Accept", "actor" => actor.uri, "object" => follow.uri}
    perform_enqueued_jobs { post_signed_activity(actor, key, accept) }
    follow.reload
    assert_equal "accepted", follow.state
    assert_equal 0, follow.probe_count
  end

  test "re-following after a lapse mints a fresh activity id" do
    actor, = create_fed_actor
    user = create_user(name: "ru#{unique_suffix}")
    follow = outbound_follow(user, actor, state: "lapsed")
    old_uri = follow.uri
    fresh = Federation::OutboxService.follow(user, actor)
    assert_equal "pending", fresh.state
    refute_equal old_uri, fresh.uri,
                 "a lapsed id may be dead in the peer's ledger; reuse would be dropped as a replay"
  end

  # --- gone actors -------------------------------------------------------------

  test "an actor answering 410 has all its edges purged, both directions" do
    actor, = create_fed_actor(last_fetched_at: 3.days.ago) # stale → liveness fetch
    user = create_user(name: "ru#{unique_suffix}")
    group = create_group(name: "rg#{unique_suffix}")
    outbound_follow(user, actor, confirmed_at: 8.days.ago)
    FedFollow.create!(local: group, fed_actor: actor, direction: "inbound",
                      state: "accepted", uri: "#{actor.uri}#follows/in")

    stub_get(actor.uri => ap_result("gone", status: 410)) do
      SVC.run
    end
    assert_equal 0, actor.fed_follows.count,
                 "a dead identity must not keep costing deliveries in either direction"
  end

  test "a transient fetch failure spends no probe and changes nothing" do
    actor, = create_fed_actor(last_fetched_at: 3.days.ago)
    user = create_user(name: "ru#{unique_suffix}")
    follow = outbound_follow(user, actor, confirmed_at: 8.days.ago)

    stub_get(actor.uri => Federation::HttpClient::Error.new("timeout")) do
      assert_no_difference "FedDelivery.count" do
        SVC.run
      end
    end
    follow.reload
    assert_equal 0, follow.probe_count
    assert_equal "accepted", follow.state
  end

  # --- moved actors ------------------------------------------------------------

  test "a peer that migrated while we were not listening is re-pointed with attestation" do
    actor, = create_fed_actor(last_fetched_at: 3.days.ago)
    old_key = OpenSSL::PKey::RSA.new(2048)
    user = create_user(name: "ru#{unique_suffix}")
    follow = outbound_follow(user, actor, confirmed_at: 8.days.ago)

    new_uri = "https://newhome.example/users/peer"
    new_key = OpenSSL::PKey::RSA.new(2048)
    stub_get(
      actor.uri => ap_result(remote_actor_doc(actor.uri, old_key, "movedTo" => new_uri)),
      new_uri => ap_result(remote_actor_doc(new_uri, new_key, "alsoKnownAs" => [actor.uri]))
    ) do
      SVC.run
    end

    refute FedFollow.exists?(follow.id), "the edge to the departed identity must be gone"
    new_actor = FedActor.find_by!(uri: new_uri)
    assert FedFollow.exists?(local: user, fed_actor: new_actor, direction: "outbound"),
           "reconciliation must repair drift from a Move we never received"
  end

  test "a moved claim without attestation re-points nothing" do
    actor, = create_fed_actor(last_fetched_at: 3.days.ago)
    old_key = OpenSSL::PKey::RSA.new(2048)
    user = create_user(name: "ru#{unique_suffix}")
    follow = outbound_follow(user, actor, confirmed_at: 8.days.ago)

    new_uri = "https://hijack.example/users/peer"
    stub_get(
      actor.uri => ap_result(remote_actor_doc(actor.uri, old_key, "movedTo" => new_uri)),
      new_uri => ap_result(remote_actor_doc(new_uri, OpenSSL::PKey::RSA.new(2048)))
    ) do
      SVC.run
    end
    assert FedFollow.exists?(follow.id), "unattested movedTo must not tear the edge down"
  end

  # --- canonical-id re-key (same-host id redirect) -----------------------------

  test "an actor that changed its canonical id form is re-keyed and still probed" do
    alias_uri = "https://peer.example/users/alice"
    canonical_uri = "https://peer.example/ap/users/42"
    actor, key = create_fed_actor(uri: alias_uri, last_fetched_at: 3.days.ago)
    user = create_user(name: "ru#{unique_suffix}")
    follow = outbound_follow(user, actor, confirmed_at: 8.days.ago)
    canonical_doc = remote_actor_doc(canonical_uri, key)

    stub_get(
      alias_uri => ap_result(canonical_doc), # doc claims the canonical id
      canonical_uri => ap_result(canonical_doc)
    ) do
      assert_difference "FedDelivery.count", 1 do
        SVC.run
      end
    end

    refute FedActor.exists?(uri: alias_uri), "the alias row must be re-keyed away"
    canonical = FedActor.find_by!(uri: canonical_uri)
    follow.reload
    assert_equal canonical.id, follow.fed_actor_id, "the edge must survive the re-key"
    assert_equal 1, follow.probe_count
    probe = FedDelivery.order(:created_at).last
    assert_equal canonical_uri, probe.payload["object"],
                 "the probe must name the canonical id, not the dead alias"
  end

  test "a cross-host id claim is not followed" do
    alias_uri = "https://peer.example/users/alice"
    actor, key = create_fed_actor(uri: alias_uri, last_fetched_at: 3.days.ago)
    user = create_user(name: "ru#{unique_suffix}")
    follow = outbound_follow(user, actor, confirmed_at: 8.days.ago)

    hijack = remote_actor_doc("https://evil.example/users/alice", key)
    stub_get(alias_uri => ap_result(hijack)) do
      assert_no_difference "FedDelivery.count" do
        SVC.run
      end
    end
    assert FedActor.exists?(uri: alias_uri), "a cross-host claim must change nothing"
    assert_equal 0, follow.reload.probe_count
  end

  test "re-keying merges into an existing canonical row and drops duplicate edges" do
    alias_uri = "https://peer.example/users/alice"
    canonical_uri = "https://peer.example/ap/users/42"
    old, key = create_fed_actor(uri: alias_uri, last_fetched_at: 3.days.ago)
    canonical, = create_fed_actor(uri: canonical_uri)
    user = create_user(name: "ru#{unique_suffix}")
    dup_via_alias = outbound_follow(user, old, confirmed_at: 8.days.ago)
    kept = outbound_follow(user, canonical, confirmed_at: 1.day.ago)
    canonical_doc = remote_actor_doc(canonical_uri, key)

    stub_get(alias_uri => ap_result(canonical_doc), canonical_uri => ap_result(canonical_doc)) do
      SVC.run
    end

    refute FedActor.exists?(uri: alias_uri)
    refute FedFollow.exists?(dup_via_alias.id), "the duplicate edge must be dropped, not doubled"
    assert_equal "accepted", kept.reload.state
  end

  # --- audience integration ----------------------------------------------------

  test "lapsed inbound edges are excluded from event fan-out" do
    owner = create_user(name: "ro#{unique_suffix}")
    group = create_group(name: "rg#{unique_suffix}", owner: owner)
    live, = create_fed_actor
    dead, = create_fed_actor
    FedFollow.create!(local: group, fed_actor: live, direction: "inbound",
                      state: "accepted", uri: "#{live.uri}#f")
    FedFollow.create!(local: group, fed_actor: dead, direction: "inbound",
                      state: "lapsed", uri: "#{dead.uri}#f")
    event = create_event(group: group, owner: owner, status: "published", visibility: "public")
    inboxes = Federation::OutboxService.event_audience_inboxes(event)
    assert_includes inboxes, live.delivery_inbox_url
    refute_includes inboxes, dead.delivery_inbox_url
  end
end
