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
    assert_equal "https://app.sola.day/users/#{@user.name}", self_link["href"]
    assert_includes body["aliases"], self_link["href"]
    subscribe = body["links"].find { |l| l["rel"] == "http://ostatus.org/schema/1.0/subscribe" }
    assert_includes subscribe["template"], "{uri}"
  end

  test "webfinger resolves a group and accepts host with :443" do
    get "/.well-known/webfinger", params: {resource: "acct:#{@group.name}@app.sola.day:443"}
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "https://app.sola.day/groups/#{@group.name}",
                 body["links"].find { |l| l["rel"] == "self" }["href"]
  end

  test "webfinger accepts URL-form resources" do
    get "/.well-known/webfinger", params: {resource: "https://app.sola.day/users/#{@user.name}"}
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

  # --- actors (AC matrix) ----------------------------------------------------

  test "user actor document satisfies Mastodon's required fields" do
    get "/users/#{@user.name}", headers: AP_ACCEPT
    assert_response :success
    assert_equal "application/activity+json", response.media_type
    doc = JSON.parse(response.body)
    assert_equal "https://app.sola.day/users/#{@user.name}", doc["id"]
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

  test "followers and outbox are valid OrderedCollections with true totals" do
    get "/groups/#{@group.name}/followers", headers: AP_ACCEPT
    assert_response :success
    doc = JSON.parse(response.body)
    assert_equal "OrderedCollection", doc["type"]
    assert_equal 0, doc["totalItems"]

    create_event(group: @group, owner: @user, visibility: "public", status: "published")
    get "/groups/#{@group.name}/outbox", headers: AP_ACCEPT
    assert_equal 1, JSON.parse(response.body)["totalItems"]
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
    assert_equal "https://app.sola.day/groups/#{@group.name}", doc["attributedTo"]
    assert_equal "CONFIRMED", doc["status"]
    assert_equal "CONFIRMED", doc["ical:status"]
    assert_equal "free", doc["joinMode"]
    assert_equal 50, doc["maximumAttendeeCapacity"]
    assert_equal 0, doc["participantCount"]
    assert doc["endTime"].present?, "endTime must never be nil (Mobilizon heuristic)"
    assert_equal ["https://www.w3.org/ns/activitystreams#Public"], doc["to"]
    assert_equal ["https://app.sola.day/groups/#{@group.name}/followers"], doc["cc"]
    assert_equal [{"type" => "Hashtag", "name" => "#web"}], doc["tag"]
    refute_includes doc["content"], "<script>", "content must be sanitized"
    assert_includes doc["summary"], "GMT+08:00"
    ext = doc["@context"].find { |c| c.is_a?(Hash) }
    assert_equal "https://mobilizon.org/ns#", ext["mz"]
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
