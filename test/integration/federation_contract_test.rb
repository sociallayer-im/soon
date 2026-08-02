require "test_helper"

# Contract tests: real payloads captured from Mobilizon, Mastodon and Gancio
# (test/fixtures/federation/upstream/, see SOURCE.md) driven through the whole
# inbound path — signature verification included, not just the converters.
#
# These are the fixture-as-contract layer of
# design/FEDERATION_INTEROP_VERIFICATION.md §3.3: our job is to handle what
# peers actually send. A fixture that changes when a reference checkout is
# upgraded is protocol drift, and these tests name what broke.
class FederationContractTest < ActionDispatch::IntegrationTest
  include FederationHelpers
  include ActiveJob::TestHelper

  FIXTURES = Rails.root.join("test/fixtures/federation/upstream")

  setup do
    ENV["FEDERATION_ENABLED"] = "true"
    Federation::RateLimiter.reset!
    @owner = create_user
    @group = create_group(owner: @owner)
    @remote, @key = create_fed_actor
  end

  teardown { ENV.delete("FEDERATION_ENABLED") }

  # Loads a fixture and re-attributes it to the signing actor. Two rewrites are
  # needed and both mirror real constraints: every id moves onto the signer's
  # host (peers require object and actor to share an origin, and so do we), and
  # every occurrence of the fixture's own actor becomes our signer's uri (the
  # inbox refuses an activity whose actor is not the one that signed it).
  def fixture(name, **over)
    json = JSON.parse(File.read(FIXTURES.join("#{name}.json")))
    json.delete("signature") # LD signature; we neither emit nor verify these
    original_actor = json["actor"]
    rehosted = deep_rehost(json)
    reattributed = original_actor ? replace_actor(rehosted, rehost(original_actor)) : rehosted
    reattributed.merge(over)
  end

  def replace_actor(node, from)
    case node
    when Hash then node.transform_values { |v| replace_actor(v, from) }
    when Array then node.map { |v| replace_actor(v, from) }
    when String then node == from ? @remote.uri : node
    else node
    end
  end

  def deep_rehost(node)
    case node
    when Hash
      node.transform_values { |v| deep_rehost(v) }
    when Array
      node.map { |v| deep_rehost(v) }
    when String
      node.match?(%r{\Ahttps?://}) ? rehost(node) : node
    else
      node
    end
  end

  def rehost(url)
    u = URI.parse(url)
    remote = URI.parse(@remote.uri)
    u.scheme = remote.scheme
    u.host = remote.host
    u.port = remote.port
    u.to_s
  rescue URI::Error
    url
  end

  def deliver(activity)
    perform_enqueued_jobs { post_signed_activity(@remote, @key, activity) }
  end

  # --- Mastodon shapes -------------------------------------------------------

  test "a real Mastodon Follow establishes the edge and gets an Accept" do
    activity = fixture("mastodon-follow-activity", "object" => Federation::Urls.actor_url(@group))
    assert_difference -> { FedFollow.count } => 1, -> { FedDelivery.count } => 1 do
      deliver(activity)
    end
    assert_response :accepted
    follow = FedFollow.last
    assert_equal activity["id"], follow.uri
    accept = FedDelivery.last.payload
    assert_equal "Accept", accept["type"]
    assert_equal activity["id"], accept["object"]["id"],
                 "the Accept must echo the exact Follow id Mastodon sent"
  end

  test "a real Mastodon Undo(Follow) removes the edge" do
    follow = fixture("mastodon-follow-activity", "object" => Federation::Urls.actor_url(@group))
    deliver(follow)
    assert_equal 1, FedFollow.count

    undo = fixture("mastodon-unfollow-activity")
    undo["object"] = undo["object"].merge("id" => follow["id"],
                                          "object" => Federation::Urls.actor_url(@group))
    deliver(undo)
    assert_response :accepted
    assert_equal 0, FedFollow.count
  end

  test "a real Mastodon Note replying to one of our events becomes a comment" do
    event = create_event(group: @group, owner: @owner, visibility: "public", status: "published")
    activity = fixture("mastodon-post-activity")
    activity["object"] = activity["object"].merge(
      "inReplyTo" => Federation::Urls.event_url(event),
      "content" => "<p>hi</p><script>evil()</script>"
    )
    assert_difference -> { Comment.count } => 1 do
      deliver(activity)
    end
    comment = Comment.last
    assert_equal event.id, comment.item_id
    assert_equal @remote.id, comment.fed_actor_id
    refute_includes comment.content, "<script>"
  end

  test "a real Mastodon Accept resolves our outbound Follow" do
    follow = Federation::OutboxService.follow(@owner, @remote)
    activity = fixture("mastodon-accept-activity")
    activity["object"] = follow.uri
    deliver(activity)
    assert_equal "accepted", follow.reload.state
  end

  test "a real Mastodon Reject marks our outbound Follow rejected" do
    follow = Federation::OutboxService.follow(@owner, @remote)
    activity = fixture("mastodon-reject-activity")
    activity["object"] = follow.uri
    deliver(activity)
    assert_equal "rejected", follow.reload.state
  end

  test "a real Mastodon Delete for something we do not hold is a silent no-op" do
    # Nebula's inbox let any caller Delete any local post. Ours only lets the
    # owning actor retire its own object, and an unknown target does nothing.
    assert_nothing_raised { deliver(fixture("mastodon-delete")) }
    assert_response :accepted
    assert_equal 0, FedEvent.count
  end

  # --- Mobilizon shapes ------------------------------------------------------

  test "a real Mobilizon Join seats a remote participant on a free event" do
    event = create_event(group: @group, owner: @owner, visibility: "public",
                         status: "published", start_time: 2.days.from_now,
                         end_time: 3.days.from_now, max_participant: 10)
    activity = fixture("mobilizon-join-activity", "object" => Federation::Urls.event_url(event))
    assert_difference -> { Participant.count } => 1 do
      deliver(activity)
    end
    part = Participant.last
    assert_equal "attending", part.status
    assert_equal @remote.id, part.fed_actor_id
    assert_equal activity["id"], part.fed_join_uri
    assert_equal "Accept", FedDelivery.last.payload["type"]
  end

  test "a real Mobilizon Leave cancels the participation" do
    event = create_event(group: @group, owner: @owner, visibility: "public",
                         status: "published", start_time: 2.days.from_now,
                         end_time: 3.days.from_now)
    join = fixture("mobilizon-join-activity", "object" => Federation::Urls.event_url(event))
    deliver(join)
    assert_equal 1, event.reload.participant_count

    # The two upstream fixtures were captured independently and happen to share
    # an activity id; a real Mobilizon Leave carries its own
    # (`<endpoint>/leave/event/<participant_id>`, actions/leave.ex:31-70).
    # Reusing the Join's id here would be indistinguishable from a replay, and
    # the ledger would correctly drop it — see the assertion below.
    leave = fixture("mobilizon-leave-activity",
                    "object" => Federation::Urls.event_url(event),
                    "id" => "#{@remote.uri}/leave/event/1")
    deliver(leave)
    assert_equal "cancelled", Participant.last.status
    assert_equal 0, event.reload.participant_count
  end

  test "an activity reusing an id already seen is dropped as a replay" do
    event = create_event(group: @group, owner: @owner, visibility: "public",
                         status: "published", start_time: 2.days.from_now,
                         end_time: 3.days.from_now)
    join = fixture("mobilizon-join-activity", "object" => Federation::Urls.event_url(event))
    deliver(join)

    # same id, different intent — the ledger is keyed on the activity id, so
    # this never reaches the handler
    leave = fixture("mobilizon-leave-activity",
                    "object" => Federation::Urls.event_url(event), "id" => join["id"])
    deliver(leave)
    assert_response :accepted
    assert_equal "attending", Participant.last.status, "replayed id must not act"
  end

  test "a real Mobilizon Create(Event) mirrors with its vocabulary intact" do
    activity = fixture("mobilizon-post-activity")
    assert_difference -> { FedEvent.count } => 1 do
      deliver(activity)
    end
    e = FedEvent.last
    object = activity["object"]
    assert_equal object["id"], e.uri
    assert_equal object["name"], e.title
    assert_equal @remote.id, e.fed_actor_id
    # the Place / PostalAddress pair Mobilizon emits
    assert_equal object.dig("location", "name"), e.location_name
    assert_equal object.dig("location", "address", "streetAddress"), e.address
  end

  # --- Gancio: the sloppy-but-valid peer -------------------------------------

  test "Gancio's Event mirrors even though its location has no type and no address" do
    activity = fixture("gancio-event-activity")
    location = activity["object"]["location"]
    refute location.key?("type"), "fixture should still be the loose shape"
    refute location.key?("address")

    assert_difference -> { FedEvent.count } => 1 do
      deliver(activity)
    end
    e = FedEvent.last
    assert_equal activity["object"]["name"], e.title
    assert_equal location["name"], e.location_name
    assert_nil e.address, "no address is fine, it must not fail the object"
  end

  # --- regressions for the defects the live lab found ------------------------
  # design/FEDERATION_INTEROP_VERIFICATION.md §9

  test "regression 1: a signature over the canonical host survives a proxy Host rewrite" do
    activity = follow_activity(@remote, @group)
    body = JSON.generate(activity)
    headers = signed_inbox_headers(@remote, @key, body).merge("Host" => "soon")
    assert_difference -> { FedFollow.count } => 1 do
      perform_enqueued_jobs { post "/inbox", params: body, headers: headers }
    end
    assert_response :accepted
  end

  test "regression 2: uuid is omitted rather than carrying a non-UUID id" do
    # Mobilizon casts uuid as Ecto.UUID; a TSID there fails the changeset and
    # the entire event is dropped, with the error only visible on their side.
    event = create_event(group: @group, owner: @owner, visibility: "public", status: "published")
    get "/events/#{event.id}", headers: {"Accept" => "application/activity+json"}
    refute JSON.parse(response.body).key?("uuid")
  end

  test "regression 3: a comment activity is signed by the actor it is attributed to" do
    event = create_event(group: @group, owner: @owner, visibility: "public", status: "published")
    comment = Comment.create!(item: event, user: @owner, comment_type: "comment",
                              content: "hello", content_type: "text")
    FedFollow.create!(local: @group, fed_actor: @remote, direction: "inbound",
                      state: "accepted", uri: "#{@remote.uri}#f/1")
    Federation::OutboxService.publish_comment(comment, event)

    delivery = FedDelivery.last
    payload = delivery.payload
    assert_equal payload["actor"], payload["object"]["attributedTo"]
    assert_equal "User", delivery.sender_type
    assert_equal @owner.id, delivery.sender_id,
                 "Mastodon drops any activity whose actor does not own the signing key"
  end

  test "regression 4: a published comment id resolves" do
    event = create_event(group: @group, owner: @owner, visibility: "public", status: "published")
    comment = Comment.create!(item: event, user: @owner, comment_type: "comment",
                              content: "hello", content_type: "text")
    get "/comments/#{comment.id}", headers: {"Accept" => "application/activity+json"}
    assert_response :success
    assert_equal "Note", JSON.parse(response.body)["type"]
  end

  test "regression 5: the instance actor webfingers, so authorized-fetch peers accept us" do
    get "/.well-known/webfinger", params: {resource: "acct:app.sola.day@app.sola.day"}
    assert_response :success
    href = JSON.parse(response.body)["links"].find { |l| l["rel"] == "self" }["href"]
    get URI.parse(href).path, headers: {"Accept" => "application/activity+json"}
    assert_equal href, JSON.parse(response.body)["id"]
  end
end
