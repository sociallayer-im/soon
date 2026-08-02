require "test_helper"

# PLAN §9.4/§9.6: custom-domain WebFinger delegation, Move semantics in both
# directions, and FEP-8b32 object integrity proofs.
class FederationMigrationTest < ActionDispatch::IntegrationTest
  include FederationHelpers
  include ActiveJob::TestHelper

  CUSTOM_DOMAIN = "hi.seven.fan".freeze

  setup do
    ENV["FEDERATION_ENABLED"] = "true"
    Federation::RateLimiter.reset!
    Federation::ActorFetchService.reset_failures!
  end

  teardown { ENV.delete("FEDERATION_ENABLED") }

  # A remote actor document that passes ActorFetchService.validate!.
  def remote_actor_doc(uri, key, also_known_as: [])
    doc = {
      "@context" => [Federation::JsonLd::AS, Federation::JsonLd::SECURITY],
      "id" => uri, "type" => "Person",
      "preferredUsername" => "mover",
      "inbox" => "#{uri}/inbox",
      "endpoints" => {"sharedInbox" => "https://#{URI.parse(uri).host}/inbox"},
      "publicKey" => {"id" => "#{uri}#main-key", "owner" => uri,
                      "publicKeyPem" => key.public_key.to_pem}
    }
    doc["alsoKnownAs"] = also_known_as if also_known_as.any?
    doc
  end

  def ap_response(doc)
    Federation::HttpClient::Result.new(
      status: 200, headers: {"content-type" => "application/activity+json"},
      body: JSON.generate(doc)
    )
  end

  # Stubs GET to serve `docs` (uri => doc) and POST to accept everything, so
  # sweeper/delivery jobs triggered inside the block never touch the network.
  def with_remote(docs, &block)
    fetcher = lambda { |uri, headers: nil|
      doc = docs[uri] or raise Federation::HttpClient::Error, "no stub for #{uri}"
      ap_response(doc)
    }
    poster = lambda { |*_args, **_kwargs|
      Federation::HttpClient::Result.new(status: 202, headers: {}, body: "")
    }
    Federation::HttpClient.stub(:get, fetcher) do
      Federation::HttpClient.stub(:post, poster, &block)
    end
  end

  # --- custom-domain binding (hi.seven.fan) ---------------------------------

  test "webfinger answers for a group's bound custom domain and closes the loop" do
    group = create_group(name: "zuseven#{unique_suffix}")
    group.update!(custom_domain: CUSTOM_DOMAIN)

    get "/.well-known/webfinger", params: {resource: "acct:#{group.name}@#{CUSTOM_DOMAIN}"}
    assert_response :success
    jrd = JSON.parse(response.body)
    assert_equal "acct:#{group.name}@#{CUSTOM_DOMAIN}", jrd["subject"]
    self_link = jrd["links"].find { |l| l["rel"] == "self" }
    assert_equal Federation::Urls.actor_url(group), self_link["href"],
                 "the actor id must stay on the canonical host"

    # canonical-host query for the same group must emit the SAME subject —
    # that is the closure Mastodon's canonicalization verifies
    get "/.well-known/webfinger", params: {resource: "acct:#{group.name}@#{Federation::Urls.host}"}
    assert_response :success
    assert_equal "acct:#{group.name}@#{CUSTOM_DOMAIN}", JSON.parse(response.body)["subject"]
  end

  test "a bound domain answers only for its own group's exact name" do
    group = create_group(name: "zuseven#{unique_suffix}")
    group.update!(custom_domain: CUSTOM_DOMAIN)
    other = create_group(name: "daospace#{unique_suffix}")

    get "/.well-known/webfinger", params: {resource: "acct:#{other.name}@#{CUSTOM_DOMAIN}"}
    assert_response :not_found

    get "/.well-known/webfinger", params: {resource: "acct:#{group.name}@unbound.example"}
    assert_response :not_found
  end

  test "a group without a custom domain keeps the canonical-host acct" do
    group = create_group(name: "daospace#{unique_suffix}")
    get "/.well-known/webfinger", params: {resource: "acct:#{group.name}@#{Federation::Urls.host}"}
    assert_response :success
    assert_equal "acct:#{group.name}@#{Federation::Urls.host}", JSON.parse(response.body)["subject"]
  end

  test "one domain binds at most one group" do
    create_group(name: "zusevena#{unique_suffix}").update!(custom_domain: CUSTOM_DOMAIN)
    dup = create_group(name: "zusevenb#{unique_suffix}")
    assert_raises(ActiveRecord::RecordInvalid) { dup.update!(custom_domain: CUSTOM_DOMAIN) }
  end

  # --- inbound Move: a remote actor we follow migrates ------------------------

  test "inbound Move re-points local follows after verifying alsoKnownAs" do
    old_actor, old_key = create_fed_actor
    user = create_user(name: "follower#{unique_suffix}")
    FedFollow.create!(local: user, fed_actor: old_actor, direction: "outbound",
                      state: "accepted", uri: "#{old_actor.uri}#follows/1")

    new_uri = "https://newhome.example/users/mover"
    new_key = OpenSSL::PKey::RSA.new(2048)
    move = {"@context" => Federation::JsonLd::AS,
            "id" => "#{old_actor.uri}#moves/1", "type" => "Move",
            "actor" => old_actor.uri, "object" => old_actor.uri, "target" => new_uri}

    with_remote(new_uri => remote_actor_doc(new_uri, new_key, also_known_as: [old_actor.uri])) do
      perform_enqueued_jobs { post_signed_activity(old_actor, old_key, move) }
    end
    assert_response :accepted

    assert_equal new_uri, old_actor.reload.moved_to
    refute FedFollow.exists?(local: user, fed_actor: old_actor, direction: "outbound"),
           "the follow of the old identity must be gone"
    new_actor = FedActor.find_by!(uri: new_uri)
    follow = FedFollow.find_by(local: user, fed_actor: new_actor, direction: "outbound")
    assert follow, "a fresh follow of the successor must exist"
    assert_equal "pending", follow.state
    assert FedDelivery.where(inbox_url: new_actor.delivery_inbox_url)
                      .any? { |d| d.payload["type"] == "Follow" },
           "the Follow activity must be queued for the new inbox"
  end

  test "a Move whose target does not attest the old identity is ignored" do
    old_actor, old_key = create_fed_actor
    user = create_user(name: "follower#{unique_suffix}")
    FedFollow.create!(local: user, fed_actor: old_actor, direction: "outbound",
                      state: "accepted", uri: "#{old_actor.uri}#follows/1")

    new_uri = "https://hijack.example/users/mover"
    move = {"@context" => Federation::JsonLd::AS,
            "id" => "#{old_actor.uri}#moves/2", "type" => "Move",
            "actor" => old_actor.uri, "object" => old_actor.uri, "target" => new_uri}

    with_remote(new_uri => remote_actor_doc(new_uri, OpenSSL::PKey::RSA.new(2048))) do
      perform_enqueued_jobs { post_signed_activity(old_actor, old_key, move) }
    end

    assert_nil old_actor.reload.moved_to
    assert FedFollow.exists?(local: user, fed_actor: old_actor, direction: "outbound"),
           "an unattested Move must not touch the follow"
  end

  test "a Move announcing someone else's identity is ignored" do
    actor, key = create_fed_actor
    victim, = create_fed_actor
    move = {"@context" => Federation::JsonLd::AS,
            "id" => "#{actor.uri}#moves/3", "type" => "Move",
            "actor" => actor.uri, "object" => victim.uri,
            "target" => "https://newhome.example/users/thief"}
    perform_enqueued_jobs { post_signed_activity(actor, key, move) }
    assert_nil victim.reload.moved_to
    assert_nil actor.reload.moved_to
  end

  test "inbound Move into a local group requires the group's alias claim" do
    old_actor, old_key = create_fed_actor
    group = create_group(name: "daospace#{unique_suffix}")
    move = {"@context" => Federation::JsonLd::AS,
            "id" => "#{old_actor.uri}#moves/4", "type" => "Move",
            "actor" => old_actor.uri, "object" => old_actor.uri,
            "target" => Federation::Urls.actor_url(group)}

    # without the claim: ignored
    perform_enqueued_jobs { post_signed_activity(old_actor, old_key, move) }
    assert_nil old_actor.reload.moved_to

    # with the claim: processed
    group.update!(fed_also_known_as: [old_actor.uri])
    move["id"] = "#{old_actor.uri}#moves/5"
    perform_enqueued_jobs { post_signed_activity(old_actor, old_key, move) }
    assert_equal Federation::Urls.actor_url(group), old_actor.reload.moved_to
  end

  # --- outbound Move: our group migrates (daospace scenario, no domain) ------

  test "moving a group broadcasts Move to followers once the target attests" do
    owner = create_user(name: "downer#{unique_suffix}")
    group = create_group(name: "daospace#{unique_suffix}", owner: owner)
    follower, = create_fed_actor
    FedFollow.create!(local: group, fed_actor: follower, direction: "inbound",
                      state: "accepted", uri: "#{follower.uri}#follows/g")

    target_uri = "https://mastodon.example/users/daospace"
    target_key = OpenSSL::PKey::RSA.new(2048)
    group_url = Federation::Urls.actor_url(group)

    # target not attesting yet → 422, nothing sent, nothing marked
    with_remote(target_uri => remote_actor_doc(target_uri, target_key)) do
      post "/api/v1/federation/groups/#{group.id}/move",
           params: {target: target_uri}, headers: auth_headers(owner)
    end
    assert_response :unprocessable_entity
    assert_nil group.reload.fed_moved_to

    Federation::ActorFetchService.reset_failures!
    with_remote(target_uri => remote_actor_doc(target_uri, target_key, also_known_as: [group_url])) do
      post "/api/v1/federation/groups/#{group.id}/move",
           params: {target: target_uri}, headers: auth_headers(owner)
      assert_response :created

      assert_equal target_uri, group.reload.fed_moved_to
      move_delivery = FedDelivery.where(inbox_url: follower.delivery_inbox_url)
                                 .detect { |d| d.payload["type"] == "Move" }
      assert move_delivery, "Move must be queued for each follower inbox"
      assert_equal group_url, move_delivery.payload["object"]
      assert_equal target_uri, move_delivery.payload["target"]

      # the actor document now tells any re-fetcher about the move
      get "/groups/#{group.id}", headers: {"Accept" => "application/activity+json"}
      assert_response :success
      assert_equal target_uri, JSON.parse(response.body)["movedTo"]
    end
  end

  test "alias endpoint records alsoKnownAs and requires manage rights" do
    owner = create_user(name: "aowner#{unique_suffix}")
    rando = create_user(name: "rando#{unique_suffix}")
    group = create_group(name: "daospace#{unique_suffix}", owner: owner)
    old_id = "https://oldhome.example/groups/daospace"

    post "/api/v1/federation/groups/#{group.id}/aliases",
         params: {uri: old_id}, headers: auth_headers(rando)
    assert_response :forbidden

    post "/api/v1/federation/groups/#{group.id}/aliases",
         params: {uri: old_id}, headers: auth_headers(owner)
    assert_response :created
    assert_includes group.reload.fed_also_known_as, old_id

    get "/groups/#{group.id}", headers: {"Accept" => "application/activity+json"}
    assert_includes JSON.parse(response.body)["alsoKnownAs"], old_id
  end

  # --- FEP-8b32 object integrity proofs ---------------------------------------

  test "served event objects carry a verifiable eddsa-jcs-2022 proof" do
    owner = create_user(name: "powner#{unique_suffix}")
    group = create_group(name: "proofgrp#{unique_suffix}", owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "public")

    get "/events/#{event.id}", headers: {"Accept" => "application/activity+json"}
    assert_response :success
    doc = JSON.parse(response.body)

    proof = doc["proof"]
    assert_equal "DataIntegrityProof", proof["type"]
    assert_equal "eddsa-jcs-2022", proof["cryptosuite"]
    assert_equal "assertionMethod", proof["proofPurpose"]
    assert_equal "#{Federation::Urls.actor_url(group)}#ed25519-key", proof["verificationMethod"]

    assert Federation::IntegrityProof.verify(doc, group.reload.fed_ed25519_public_key),
           "the served proof must verify against the group's multikey"
    tampered = doc.merge("name" => "tampered title")
    refute Federation::IntegrityProof.verify(tampered, group.fed_ed25519_public_key),
           "any content change must invalidate the proof"
  end

  test "actor documents publish the Ed25519 Multikey as assertionMethod" do
    group = create_group(name: "keygrp#{unique_suffix}")
    get "/groups/#{group.id}", headers: {"Accept" => "application/activity+json"}
    assert_response :success
    method = JSON.parse(response.body)["assertionMethod"].first
    assert_equal "Multikey", method["type"]
    assert_equal Federation::Urls.actor_url(group), method["controller"]
    assert method["publicKeyMultibase"].start_with?("z6Mk"),
           "an Ed25519 multikey always encodes to a z6Mk… string"
    # and it round-trips into the key the proofs verify with
    assert_equal 32, Federation::Multibase
                       .decode_ed25519_public_key(method["publicKeyMultibase"]).bytesize
  end

  test "proof determinism: same content serializes to the same proofValue" do
    owner = create_user(name: "downer2#{unique_suffix}")
    group = create_group(name: "detgrp#{unique_suffix}", owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "public")
    a = Federation::EventSerializer.new(event).as_ap
    b = Federation::EventSerializer.new(event.reload).as_ap
    assert_equal a["proof"]["proofValue"], b["proof"]["proofValue"],
                 "created is pinned to updated_at, so proofs must be reproducible"
  end

  test "JCS canonicalization matches RFC 8785 semantics" do
    assert_equal '{"literals":[null,true,false],"numbers":[333333333,1,10,0]}',
                 Federation::Jcs.canonicalize(
                   {"numbers" => [333333333, 1, 10, 0.0], "literals" => [nil, true, false]}
                 )
    # UTF-16 code-unit key ordering: astral-plane emoji sorts before U+FF01
    sorted = Federation::Jcs.canonicalize({"！" => 1, "😀" => 2})
    assert sorted.index("😀".b) < sorted.index("！".b),
           "surrogate pairs sort below U+E000..U+FFFF in UTF-16 order"
    assert_equal %q("a\\nb"), Federation::Jcs.serialize("a\nb")
    assert_equal %q("\\u0007"), Federation::Jcs.serialize("\a")
  end

  test "an inbound event with a broken proof is still mirrored (warn-only)" do
    remote, key = create_fed_actor(actor_type: "Group")
    event_uri = "https://#{remote.domain}/events/badproof"
    object = {
      "type" => "Event", "id" => event_uri, "attributedTo" => remote.uri,
      "name" => "Remote party", "startTime" => 2.days.from_now.utc.iso8601,
      "to" => [Federation::JsonLd::PUBLIC],
      "proof" => {"type" => "DataIntegrityProof", "cryptosuite" => "eddsa-jcs-2022",
                  "proofPurpose" => "assertionMethod", "created" => Time.now.utc.iso8601,
                  "verificationMethod" => "#{remote.uri}#ed25519-key",
                  "proofValue" => "zinvalid"}
    }
    activity = {"@context" => Federation::JsonLd::AS, "id" => "#{event_uri}/activity/create",
                "type" => "Create", "actor" => remote.uri, "object" => object}
    perform_enqueued_jobs { post_signed_activity(remote, key, activity) }
    assert_response :accepted
    assert FedEvent.exists?(uri: event_uri),
           "HTTP-signature transport identity wins; a bad embedded proof only warns"
  end
end
