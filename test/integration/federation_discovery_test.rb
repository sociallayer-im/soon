require "test_helper"

# Phase 1 L0 discovery matrix (design/FEDERATION_INTEROP_VERIFICATION.md §2).
# Assertions encode Mastodon's acceptance rules — exact self-link type string,
# id == fetched URI, content types — and the feature-flag gate.
class FederationDiscoveryTest < ActionDispatch::IntegrationTest
  AP_ACCEPT = {"Accept" => "application/activity+json"}.freeze

  setup do
    ENV["FEDERATION_ENABLED"] = "true"
    @user = create_user
    @group = create_group
  end

  teardown do
    ENV.delete("FEDERATION_ENABLED")
  end

  # --- feature flag ----------------------------------------------------------

  test "everything 404s while federation is disabled" do
    ENV.delete("FEDERATION_ENABLED")
    get "/.well-known/webfinger", params: {resource: "acct:#{@user.name}@app.sola.day"}
    assert_response :not_found
    get "/users/#{@user.name}", headers: AP_ACCEPT
    assert_response :not_found
    get "/nodeinfo/2.0"
    assert_response :not_found
  end

  # --- webfinger (WF matrix) -------------------------------------------------

  test "webfinger resolves a user with the exact self-link contract" do
    get "/.well-known/webfinger", params: {resource: "acct:#{@user.name}@app.sola.day"}
    assert_response :success
    assert_equal "application/jrd+json", response.media_type
    body = JSON.parse(response.body)
    assert_equal "acct:#{@user.name}@app.sola.day", body["subject"]
    self_link = body["links"].find { |l| l["rel"] == "self" }
    assert_equal "application/activity+json", self_link["type"]
    assert_equal "https://app.sola.day/users/#{@user.id}", self_link["href"]
    assert_includes body["aliases"], self_link["href"]
    subscribe = body["links"].find { |l| l["rel"] == "http://ostatus.org/schema/1.0/subscribe" }
    assert_includes subscribe["template"], "{uri}"
  end

  test "webfinger resolves a group and accepts host with :443" do
    get "/.well-known/webfinger", params: {resource: "acct:#{@group.name}@app.sola.day:443"}
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "https://app.sola.day/groups/#{@group.id}",
                 body["links"].find { |l| l["rel"] == "self" }["href"]
  end

  test "webfinger accepts URL-form resources" do
    get "/.well-known/webfinger", params: {resource: "https://app.sola.day/users/#{@user.id}"}
    assert_response :success
  end

  test "webfinger 404s unknown users and foreign hosts, 400s missing resource" do
    get "/.well-known/webfinger", params: {resource: "acct:nobody_here@app.sola.day"}
    assert_response :not_found
    get "/.well-known/webfinger", params: {resource: "acct:#{@user.name}@evil.example"}
    assert_response :not_found
    get "/.well-known/webfinger"
    assert_response :bad_request
  end

  test "webfinger self href loops back to the actor id (Mastodon's hard requirement)" do
    get "/.well-known/webfinger", params: {resource: "acct:#{@user.name}@app.sola.day"}
    href = JSON.parse(response.body)["links"].find { |l| l["rel"] == "self" }["href"]
    get URI.parse(href).path, headers: AP_ACCEPT
    assert_response :success
    assert_equal href, JSON.parse(response.body)["id"]
  end

  test "host-meta serves the lrdd template" do
    get "/.well-known/host-meta"
    assert_response :success
    assert_equal "application/xrd+xml", response.media_type
    assert_includes response.body, "/.well-known/webfinger?resource={uri}"
  end

  test "webfinger answers for the instance actor under its host-as-username" do
    # Mastodon in authorized-fetch mode verifies the signer of our outbound
    # GETs by webfingering acct:<preferredUsername>@<host> and requiring the
    # self link to loop back to the actor id. Our instance actor's username is
    # the host, so this lookup must resolve — without it every signed fetch
    # 401s and secure-mode instances can read nothing of ours.
    get "/.well-known/webfinger", params: {resource: "acct:app.sola.day@app.sola.day"}
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "acct:app.sola.day@app.sola.day", body["subject"]
    href = body["links"].find { |l| l["rel"] == "self" }["href"]
    assert_equal "https://app.sola.day/actor", href

    get URI.parse(href).path, headers: AP_ACCEPT
    doc = JSON.parse(response.body)
    assert_equal href, doc["id"], "actor id must equal the webfinger self href"
    assert_equal "app.sola.day", doc["preferredUsername"]
  end

  test "webfinger resolves the instance actor by URL too" do
    get "/.well-known/webfinger", params: {resource: "https://app.sola.day/actor"}
    assert_response :success
    assert_equal "acct:app.sola.day@app.sola.day", JSON.parse(response.body)["subject"]
  end

  # --- actors (AC matrix) ----------------------------------------------------

  test "user actor document satisfies Mastodon's required fields" do
    get "/users/#{@user.name}", headers: AP_ACCEPT
    assert_response :success
    assert_equal "application/activity+json", response.media_type
    doc = JSON.parse(response.body)
    assert_equal "https://app.sola.day/users/#{@user.id}", doc["id"]
    assert_equal "Person", doc["type"]
    assert_equal @user.name, doc["preferredUsername"]
    assert doc["inbox"].present?
    assert_includes Array(doc["@context"]), "https://www.w3.org/ns/activitystreams"
    key = doc["publicKey"]
    assert_equal "#{doc['id']}#main-key", key["id"]
    assert_equal doc["id"], key["owner"]
    assert OpenSSL::PKey::RSA.new(key["publicKeyPem"]).public?
    assert_equal "https://app.sola.day/inbox", doc["endpoints"]["sharedInbox"]
  end

  test "serving an actor lazily mints its keypair once" do
    assert_nil @user.fed_public_key
    2.times { get "/users/#{@user.name}", headers: AP_ACCEPT }
    assert @user.reload.fed_public_key.present?
  end

  test "group actor is type Group" do
    get "/groups/#{@group.name}", headers: AP_ACCEPT
    doc = JSON.parse(response.body)
    assert_equal "Group", doc["type"]
    assert_equal @group.memberships_count, doc["memberCount"]
  end

  test "browser Accept redirects to the human profile page" do
    get "/users/#{@user.name}", headers: {"Accept" => "text/html"}
    assert_response :redirect
    assert_includes response.headers["Location"], "/profile/#{@user.name}"
  end

  test "instance actor serves at /actor with a stable key" do
    get "/actor", headers: AP_ACCEPT
    assert_response :success
    doc = JSON.parse(response.body)
    assert_equal "Application", doc["type"]
    first_pem = doc["publicKey"]["publicKeyPem"]
    get "/actor", headers: AP_ACCEPT
    assert_equal first_pem, JSON.parse(response.body)["publicKey"]["publicKeyPem"]
  end

  # --- collections -----------------------------------------------------------

  test "collections are paged, and totalItems is the real total not the page size" do
    # nebula returned every follower at once and reported its 100-item outbox
    # cap as the total; both were named as things not to repeat.
    get "/groups/#{@group.name}/followers", headers: AP_ACCEPT
    assert_response :success
    doc = JSON.parse(response.body)
    assert_equal "OrderedCollection", doc["type"]
    assert_equal 0, doc["totalItems"]
    assert_equal "https://app.sola.day/groups/#{@group.id}/followers?page=0", doc["first"]
    refute doc.key?("orderedItems"), "the collection head carries no items"

    3.times { create_event(group: @group, owner: @user, visibility: "public", status: "published") }
    get "/groups/#{@group.name}/outbox", headers: AP_ACCEPT
    assert_equal 3, JSON.parse(response.body)["totalItems"]

    get "/groups/#{@group.name}/outbox", params: {page: 0}, headers: AP_ACCEPT
    page = JSON.parse(response.body)
    assert_equal "OrderedCollectionPage", page["type"]
    assert_equal 3, page["totalItems"]
    assert_equal 3, page["orderedItems"].size
    assert_equal "https://app.sola.day/groups/#{@group.id}/outbox", page["partOf"]
    refute page.key?("next"), "a single page must not advertise another"
    refute page.key?("prev")
  end

  test "follower pages list actor uris and chain with next/prev" do
    actors = 3.times.map { |i|
      a = FedActor.create!(uri: "https://remote#{i}.example/users/a", domain: "remote#{i}.example",
                           actor_type: "Person", preferred_username: "a",
                           inbox_url: "https://remote#{i}.example/users/a/inbox")
      FedFollow.create!(local: @group, fed_actor: a, direction: "inbound",
                        state: "accepted", uri: "#{a.uri}#f")
      a
    }

    get "/groups/#{@group.name}/followers", headers: AP_ACCEPT
    assert_equal 3, JSON.parse(response.body)["totalItems"]

    get "/groups/#{@group.name}/followers", params: {page: 0}, headers: AP_ACCEPT
    items = JSON.parse(response.body)["orderedItems"]
    assert_equal actors.map(&:uri).sort, items.sort

    # a page past the end is clamped to the last real page (P2-3: an
    # arbitrary ?page=10^9 must not buy a deep-OFFSET scan)
    get "/groups/#{@group.name}/followers", params: {page: 5}, headers: AP_ACCEPT
    assert_response :success
    doc = JSON.parse(response.body)
    assert_equal "https://app.sola.day/groups/#{@group.id}/followers?page=0", doc["id"]
    assert_equal 3, doc["orderedItems"].size
    assert_nil doc["next"]
  end

  test "a negative page number does not escape the first page" do
    get "/groups/#{@group.name}/followers", params: {page: -3}, headers: AP_ACCEPT
    assert_response :success
    assert_equal "https://app.sola.day/groups/#{@group.id}/followers?page=0",
                 JSON.parse(response.body)["id"]
  end

  # --- event objects (§2.4 shape, Mobilizon-aligned) -------------------------

  test "public published event serves the Mobilizon-aligned AP shape" do
    event = create_event(group: @group, owner: @user, visibility: "public", status: "published",
                         title: "Fed Meetup", content: "<p>hi</p><script>x()</script>",
                         tags: ["web"], max_participant: 50, timezone: "Asia/Singapore")
    get "/events/#{event.id}", headers: AP_ACCEPT
    assert_response :success
    doc = JSON.parse(response.body)
    assert_equal "Event", doc["type"]
    assert_equal "https://app.sola.day/events/#{event.id}", doc["id"]
    assert_equal "https://app.sola.day/event/detail/#{event.id}", doc["url"]
    assert_equal "https://app.sola.day/groups/#{@group.id}", doc["attributedTo"]
    assert_equal "CONFIRMED", doc["status"]
    assert_equal "CONFIRMED", doc["ical:status"]
    assert_equal "free", doc["joinMode"]
    assert_equal 50, doc["maximumAttendeeCapacity"]
    assert_equal 0, doc["participantCount"]
    assert doc["endTime"].present?, "endTime must never be nil (Mobilizon heuristic)"
    assert_equal ["https://www.w3.org/ns/activitystreams#Public"], doc["to"]
    assert_equal ["https://app.sola.day/groups/#{@group.id}/followers"], doc["cc"]
    assert_equal [{"type" => "Hashtag", "name" => "#web"}], doc["tag"]
    refute_includes doc["content"], "<script>", "content must be sanitized"
    assert_includes doc["summary"], "GMT+08:00"
    ext = doc["@context"].find { |c| c.is_a?(Hash) }
    assert_equal "https://mobilizon.org/ns#", ext["mz"]
  end

  test "uuid is omitted when the id is not a UUID" do
    # Mobilizon casts uuid as Ecto.UUID; a TSID there fails the changeset and
    # the entire event is dropped. Verified against a live 5.2.4 instance.
    event = create_event(group: @group, owner: @user, visibility: "public", status: "published")
    refute_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, event.id, "fixture should have a TSID id")
    get "/events/#{event.id}", headers: AP_ACCEPT
    refute JSON.parse(response.body).key?("uuid")
  end

  test "require_approval maps to restricted, tickets map to external" do
    restricted = create_event(group: @group, owner: @user, visibility: "public",
                              status: "published", require_approval: true)
    get "/events/#{restricted.id}", headers: AP_ACCEPT
    assert_equal "restricted", JSON.parse(response.body)["joinMode"]
  end

  test "draft, pending and private events are not served" do
    draft = create_event(group: @group, owner: @user, visibility: "public", status: "draft")
    priv = create_event(group: @group, owner: @user, visibility: "private", status: "published")
    get "/events/#{draft.id}", headers: AP_ACCEPT
    assert_response :not_found
    get "/events/#{priv.id}", headers: AP_ACCEPT
    assert_response :not_found
  end

  test "cancelled event serves with CANCELLED status" do
    event = create_event(group: @group, owner: @user, visibility: "public", status: "cancelled")
    get "/events/#{event.id}", headers: AP_ACCEPT
    assert_response :success
    assert_equal "CANCELLED", JSON.parse(response.body)["ical:status"]
  end

  test "a comment on a public event is dereferenceable as a Note" do
    # Peers follow inReplyTo when resolving a thread, so the id we publish has
    # to resolve. Mastodon also drops any activity whose actor does not own the
    # signing key, which is why the note is attributed to the signer.
    event = create_event(group: @group, owner: @user, visibility: "public", status: "published")
    comment = Comment.create!(item: event, user: @user, comment_type: "comment",
                              content: "<p>hi</p><script>x()</script>", content_type: "text")
    get "/comments/#{comment.id}", headers: AP_ACCEPT
    assert_response :success
    doc = JSON.parse(response.body)
    assert_equal "Note", doc["type"]
    assert_equal "https://app.sola.day/comments/#{comment.id}", doc["id"]
    assert_equal "https://app.sola.day/users/#{@user.id}", doc["attributedTo"]
    assert_equal doc["attributedTo"], doc["actor"], "signer and attribution must agree"
    assert_equal "https://app.sola.day/events/#{event.id}", doc["inReplyTo"]
    refute_includes doc["content"], "<script>"
  end

  test "comments on non-public events are not served" do
    event = create_event(group: @group, owner: @user, visibility: "private", status: "published")
    comment = Comment.create!(item: event, user: @user, comment_type: "comment",
                              content: "secret", content_type: "text")
    get "/comments/#{comment.id}", headers: AP_ACCEPT
    assert_response :not_found
  end

  # --- identity stability (the reason actor ids are not handles) -------------

  test "renaming an actor does not move its federated identity" do
    get "/.well-known/webfinger", params: {resource: "acct:#{@group.name}@app.sola.day"}
    href_before = JSON.parse(response.body)["links"].find { |l| l["rel"] == "self" }["href"]

    @group.update!(name: "renamed#{SecureRandom.hex(3)}")

    # the old id still resolves — peers hold it, and it must not 404
    get URI.parse(href_before).path, headers: AP_ACCEPT
    assert_response :success
    assert_equal href_before, JSON.parse(response.body)["id"]

    # and webfinger on the NEW handle loops back to that same id, which is what
    # Mastodon re-checks after a username change
    get "/.well-known/webfinger", params: {resource: "acct:#{@group.name}@app.sola.day"}
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal href_before, body["links"].find { |l| l["rel"] == "self" }["href"]
    assert_equal "acct:#{@group.name}@app.sola.day", body["subject"]
  end

  test "an actor still resolves by handle, so cached handle URLs keep working" do
    get "/groups/#{@group.name}", headers: AP_ACCEPT
    assert_response :success
    # but the canonical id it reports is the stable one
    assert_equal "https://app.sola.day/groups/#{@group.id}", JSON.parse(response.body)["id"]
  end

  test "the instance actor's advertised outbox resolves" do
    get "/actor", headers: AP_ACCEPT
    outbox = JSON.parse(response.body)["outbox"]
    get URI.parse(outbox).path, headers: AP_ACCEPT
    assert_response :success
    doc = JSON.parse(response.body)
    assert_equal "OrderedCollection", doc["type"]
    assert_equal outbox, doc["id"]
  end

  # --- nodeinfo (NI matrix) --------------------------------------------------

  test "nodeinfo discovery chains to a valid 2.0 document" do
    get "/.well-known/nodeinfo"
    assert_response :success
    href = JSON.parse(response.body)["links"].first["href"]
    assert_equal "https://app.sola.day/nodeinfo/2.0", href
    get "/nodeinfo/2.0"
    doc = JSON.parse(response.body)
    assert_equal "2.0", doc["version"]
    assert_equal "sola", doc["software"]["name"]
    assert_equal ["activitypub"], doc["protocols"]
    assert doc["usage"]["users"]["total"].is_a?(Integer)
  end
end
