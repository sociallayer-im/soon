require "test_helper"

# Phase 2 inbox gauntlet + Follow/Undo semantics
# (design/FEDERATION_TEST_PLAN.md §2.5/§3.1/§3.2, §6 BL/RL matrices).
class FederationInboxTest < ActionDispatch::IntegrationTest
  include FederationHelpers
  include ActiveJob::TestHelper

  setup do
    ENV["FEDERATION_ENABLED"] = "true"
    Rails.cache.clear
    Federation::RateLimiter.reset!
    Federation::ActorFetchService.reset_failures!
    @group = create_group
    @remote, @key = create_fed_actor
  end

  teardown do
    ENV.delete("FEDERATION_ENABLED")
    ENV.delete("FEDERATION_MODE")
  end

  # --- happy path: Follow → stored + Accept queued ---------------------------

  test "signed Follow creates an inbound follow and queues an Accept" do
    activity = follow_activity(@remote, @group)
    assert_difference -> { FedFollow.count } => 1, -> { FedDelivery.count } => 1 do
      perform_enqueued_jobs do
        post_signed_activity(@remote, @key, activity)
      end
    end
    assert_response :accepted

    follow = FedFollow.last
    assert_equal "inbound", follow.direction
    assert_equal "accepted", follow.state
    assert_equal activity["id"], follow.uri
    assert_equal @group, follow.local

    accept = FedDelivery.last
    assert_equal "Accept", accept.payload["type"]
    # the Accept must echo the original Follow verbatim — Mastodon matches on it
    assert_equal activity["id"], accept.payload["object"]["id"]
    assert_equal Federation::Urls.actor_url(@group), accept.payload["actor"]
    assert_equal @remote.delivery_inbox_url, accept.inbox_url
  end

  test "repeat Follow is idempotent on the edge and re-Accepts" do
    perform_enqueued_jobs { post_signed_activity(@remote, @key, follow_activity(@remote, @group)) }
    assert_difference -> { FedFollow.count } => 0, -> { FedDelivery.count } => 1 do
      perform_enqueued_jobs { post_signed_activity(@remote, @key, follow_activity(@remote, @group)) }
    end
  end

  test "Undo with inlined Follow removes the edge; unknown Undo is a silent no-op" do
    follow = follow_activity(@remote, @group)
    perform_enqueued_jobs { post_signed_activity(@remote, @key, follow) }
    undo = {"@context" => Federation::JsonLd::AS, "id" => "#{@remote.uri}#undo/1",
            "type" => "Undo", "actor" => @remote.uri, "object" => follow}
    perform_enqueued_jobs { post_signed_activity(@remote, @key, undo) }
    assert_response :accepted
    assert_equal 0, FedFollow.where(local: @group).count

    unknown_undo = undo.merge("id" => "#{@remote.uri}#undo/2")
    perform_enqueued_jobs { post_signed_activity(@remote, @key, unknown_undo) }
    assert_response :accepted
  end

  test "unknown activity types are accepted then ignored (no probe signal)" do
    activity = follow_activity(@remote, @group).merge("type" => "Arrive")
    assert_no_difference -> { FedFollow.count } do
      perform_enqueued_jobs { post_signed_activity(@remote, @key, activity) }
    end
    assert_response :accepted
  end

  # --- idempotency (OO-1) ----------------------------------------------------

  test "duplicate activity id is a 202 no-op" do
    activity = follow_activity(@remote, @group)
    perform_enqueued_jobs { post_signed_activity(@remote, @key, activity) }
    assert_no_difference -> { FedDelivery.count } do
      perform_enqueued_jobs { post_signed_activity(@remote, @key, activity) }
    end
    assert_response :accepted
    assert_equal 1, FedInboundActivity.where(uri: activity["id"]).count
  end

  # --- signature gauntlet ----------------------------------------------------

  test "unsigned POST is 401 with no side effects" do
    assert_no_difference -> { FedFollow.count } do
      post "/inbox", params: JSON.generate(follow_activity(@remote, @group)),
                     headers: {"Content-Type" => "application/activity+json"}
    end
    assert_response :unauthorized
  end

  test "tampered body is 401" do
    activity = follow_activity(@remote, @group)
    body = JSON.generate(activity)
    headers = signed_inbox_headers(@remote, @key, body)
    post "/inbox", params: body.sub("Follow", "Delete"), headers: headers
    assert_response :unauthorized
  end

  test "stale Date is 401" do
    post_signed_activity(@remote, @key, follow_activity(@remote, @group), date: 3.hours.ago)
    assert_response :unauthorized
  end

  test "payload actor different from the signer is 401 (SV-1)" do
    activity = follow_activity(@remote, @group).merge("actor" => "https://other.example/users/mallory")
    post_signed_activity(@remote, @key, activity)
    assert_response :unauthorized
  end

  test "oversized payload is 413, bad JSON is 400" do
    post "/inbox", params: "x" * (1.megabyte + 1),
                   headers: {"Content-Type" => "application/activity+json"}
    assert_response 413

    body = "{not json"
    post "/inbox", params: body, headers: signed_inbox_headers(@remote, @key, body)
    assert_response :bad_request
  end

  # --- reverse proxy in front of the inbox -----------------------------------

  test "signature signed for the canonical host verifies after a proxy rewrites Host" do
    # The canonical host proxies AP paths here and replaces Host with its
    # upstream target, so the value the sender signed never reaches us. Caught
    # against a live Mastodon: every inbound Follow 401'd.
    activity = follow_activity(@remote, @group)
    body = JSON.generate(activity)
    headers = signed_inbox_headers(@remote, @key, body) # signs Host: app.sola.day
    headers["Host"] = "soon" # what the proxy actually forwards

    assert_difference -> { FedFollow.count } => 1 do
      perform_enqueued_jobs { post "/inbox", params: body, headers: headers }
    end
    assert_response :accepted
  end

  test "a forged X-Forwarded-Host cannot make a foreign-signed request verify" do
    activity = follow_activity(@remote, @group)
    body = JSON.generate(activity)
    # signed for someone else's host entirely
    headers = Federation::HttpSignature.sign(
      method: :post, url: "https://victim.example/inbox",
      key_id: @remote.key_id, private_key: @key.to_pem, body: body
    ).merge("Content-Type" => "application/activity+json",
            "X-Forwarded-Host" => "victim.example", "Host" => "soon")

    assert_no_difference -> { FedFollow.count } do
      post "/inbox", params: body, headers: headers
    end
    assert_response :unauthorized
  end

  # --- governance (BL matrix) ------------------------------------------------

  test "blocked domain is 403 before any processing" do
    FedDomainPolicy.create!(domain: @remote.domain, policy: "blocked")
    assert_no_difference -> { FedFollow.count } do
      post_signed_activity(@remote, @key, follow_activity(@remote, @group))
    end
    assert_response :forbidden
    assert_operator FedDomainStat.for(@remote.domain).inbound_rejected_count, :>=, 1
  end

  test "allowlist mode rejects valid signatures from unlisted domains (WL-1)" do
    ENV["FEDERATION_MODE"] = "allowlist"
    post_signed_activity(@remote, @key, follow_activity(@remote, @group))
    assert_response :forbidden

    FedDomainPolicy.create!(domain: @remote.domain, policy: "allowed")
    perform_enqueued_jobs { post_signed_activity(@remote, @key, follow_activity(@remote, @group)) }
    assert_response :accepted
  end

  test "policy change takes effect on the next request (BL-5)" do
    perform_enqueued_jobs { post_signed_activity(@remote, @key, follow_activity(@remote, @group)) }
    assert_response :accepted
    FedDomainPolicy.create!(domain: @remote.domain, policy: "blocked")
    post_signed_activity(@remote, @key, follow_activity(@remote, @group).merge("id" => "#{@remote.uri}#f2"))
    assert_response :forbidden
  end

  test "blocked actor is 403 even when its domain is fine (BL-6)" do
    @remote.update!(blocked_at: Time.current)
    post_signed_activity(@remote, @key, follow_activity(@remote, @group))
    assert_response :forbidden
  end

  # --- rate limits (RL matrix) -----------------------------------------------

  test "per-actor Follow flood hits 429 with Retry-After (RL-3)" do
    statuses = 12.times.map { |i|
      post_signed_activity(@remote, @key,
                           follow_activity(@remote, @group, id: "#{@remote.uri}#flood/#{i}"))
      response.status
    }
    assert_includes statuses, 429
    assert response.headers["Retry-After"].present?
  end

  test "domain rate limit isolates other domains (RL-2)" do
    other, other_key = create_fed_actor
    111.times { |i| Federation::RateLimiter.allow?(:domain, @remote.domain) }
    # @remote's domain is near the cap; other domain must be unaffected
    perform_enqueued_jobs { post_signed_activity(other, other_key, follow_activity(other, @group)) }
    assert_response :accepted
  end

  # --- observability (OM-2) --------------------------------------------------

  test "inbound counters track accepts and rejects" do
    perform_enqueued_jobs { post_signed_activity(@remote, @key, follow_activity(@remote, @group)) }
    post "/inbox", params: "{}", headers: {"Content-Type" => "application/activity+json"}
    stat = FedDomainStat.for(@remote.domain)
    assert_operator stat.inbound_count, :>=, 1
  end
  # --- amplification (TEST_PLAN §6.1 RL-7) -----------------------------------

  test "forged keyIds cannot turn the inbox into an outbound amplifier" do
    # Every unknown keyId costs one outbound fetch. Without a brake, N forged
    # ids become N outbound requests, each holding a request thread for the
    # length of the HTTP timeout.
    fetches = 0
    fetcher = lambda { |_uri, headers: nil|
      fetches += 1
      raise Federation::HttpClient::Error, "unreachable"
    }

    Federation::HttpClient.stub(:get, fetcher) do
      20.times do |i|
        key_id = "https://forged.example/users/x#{i}#main-key"
        body = JSON.generate({"@context" => Federation::JsonLd::AS,
                              "id" => "https://forged.example/a/#{i}", "type" => "Follow",
                              "actor" => "https://forged.example/users/x#{i}",
                              "object" => Federation::Urls.actor_url(@group)})
        headers = Federation::HttpSignature.sign(
          method: :post, url: "https://app.sola.day/inbox",
          key_id: key_id, private_key: @key.to_pem, body: body
        ).merge("Content-Type" => "application/activity+json")
        post "/inbox", params: body, headers: headers
        assert_response :unauthorized
      end
    end

    limit, = Federation::RateLimiter::LIMITS.fetch(:discovery)
    assert_operator fetches, :<=, limit,
                    "outbound fetches must stay under the discovery cap, got #{fetches}"
    assert_equal 0, FedFollow.count
  end

  test "a keyId that just failed is not fetched again" do
    fetches = 0
    fetcher = lambda { |_uri, headers: nil|
      fetches += 1
      raise Federation::HttpClient::Error, "unreachable"
    }
    key_id = "https://forged.example/users/same#main-key"

    Federation::HttpClient.stub(:get, fetcher) do
      5.times do |i|
        body = JSON.generate({"@context" => Federation::JsonLd::AS,
                              "id" => "https://forged.example/same/#{i}", "type" => "Follow",
                              "actor" => "https://forged.example/users/same",
                              "object" => Federation::Urls.actor_url(@group)})
        headers = Federation::HttpSignature.sign(
          method: :post, url: "https://app.sola.day/inbox",
          key_id: key_id, private_key: @key.to_pem, body: body
        ).merge("Content-Type" => "application/activity+json")
        post "/inbox", params: body, headers: headers
      end
    end
    assert_equal 1, fetches, "the same failing keyId must be fetched once, not once per request"
  end
end
