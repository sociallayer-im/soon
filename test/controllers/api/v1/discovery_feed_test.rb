require "test_helper"

class Api::V1::DiscoveryFeedTest < ActionDispatch::IntegrationTest
  setup do
    @old_discussion = ENV["DISCUSSION_ENABLED"]
    ENV["DISCUSSION_ENABLED"] = "true"
    @owner = create_user
    @viewer = create_user
    @friend = create_user
    @local = create_group(owner: @owner, city: "上海市")
    @remote = create_group(owner: @owner, city: "杭州")
    @now = Time.current
  end
  teardown { ENV["DISCUSSION_ENABLED"] = @old_discussion }

  def event(group: @local, owner: @owner, **attrs)
    create_event(group: group, owner: owner, start_time: @now+1.day, end_time: @now+1.day+1.hour, status: "published", visibility: "normal", **attrs)
  end

  test "home uses group city, prioritizes followed hosts and excludes stale hidden or unreviewed contents" do
    regular = event
    related = event(owner: @friend, start_time: @now+2.days, end_time: @now+2.days+1.hour)
    event(group: @remote)
    event(status: "cancelled")
    event(visibility: "unlisted")
    event(start_time: @now-2.days, end_time: @now-1.day)
    pending = create_group(city: "上海", active: false, review_status: "pending")
    event(group: pending)
    Follow.create!(user: @viewer, target: @friend, status: "active")
    get "/api/v1/discovery/home", params: {city: "Shanghai"}, headers: auth_headers(@viewer)
    assert_response :success
    assert_equal [related.id, regular.id], json_response["events"].map { |e| e["id"] }
    assert_equal "上海", json_response["city"]
    assert json_response["cities"].include?("上海")
    assert_equal "上海", @local.reload.browse_city
  end

  test "guest timeline exhausts all city events beyond recommendation pool without reasons or duplicates" do
    expected = 125.times.map { |i| event(start_time: @now+(i+1).hours, end_time: @now+(i+2).hours) }
    seen = []
    cursor = nil
    10.times do
      result = DiscoveryFeed.new(user: nil).page("events", limit: 20, cursor: cursor)
      assert result[:data].all? { |row| row["recommendation_reason"].nil? }
      seen.concat(result[:data].map { |row| row["id"] })
      cursor = result[:next_cursor]
      break unless cursor
    end
    assert_nil cursor
    assert_equal expected.map(&:id), seen
    assert_equal seen.uniq, seen
  end

  test "personalized prefix continues into complete chronological tail including own agenda" do
    regular = event(start_time: @now+1.hour)
    related = event(owner: @friend, start_time: @now+2.days, end_time: @now+3.days)
    Follow.create!(user: @viewer, target: @friend, status: "active")
    Participant.create!(event: regular, user: @viewer, status: "attending")
    first = DiscoveryFeed.new(user: @viewer).page("events", limit: 1)
    assert_equal [related.id], first[:data].map { |row| row["id"] }
    second = DiscoveryFeed.new(user: @viewer).page("events", limit: 1, cursor: first[:next_cursor])
    assert_equal [regular.id], second[:data].map { |row| row["id"] }
    assert_nil second[:next_cursor]
  end

  test "agenda includes settled attendees and linked guests without duplicate bookings" do
    attending = event
    unpaid = event
    guest = event(group: @remote)
    Participant.create!(event: attending, user: @viewer, status: "attending")
    Participant.create!(event: unpaid, user: @viewer, status: "attending", payment_status: "pending")
    EventRole.create!(event: guest, item: @viewer, role: "speaker")
    get "/api/v1/discovery/home", headers: auth_headers(@viewer)
    assert_response :success
    assert_equal [attending.id, guest.id].sort, json_response["upcoming"].map { |e| e["id"] }.sort
    assert json_response["upcoming"].all? { |e| e["is_attending"] }
  end

  test "community embeds post excerpts and linked activity in batches without private data" do
    category = create_category(group: @local)
    linked = event
    post = create_topic(category: category, user: @friend, content: "内容"*2000, event: linked, sync_to_community: true)
    hidden = create_category(group: @local, visibility: "member")
    create_topic(category: hidden, user: @friend)
    create_topic(category: category, user: @friend, event: event(visibility: "unlisted"), sync_to_community: true)
    get "/api/v1/discovery/community", headers: auth_headers(@viewer)
    assert_response :success
    assert_equal [post.id], json_response["topics"].map { |t| t["id"] }
    card = json_response["topics"].first
    assert_equal 1200, card["content"].length
    assert_equal linked.id, card.dig("event", "id")
    assert_equal @local.nickname || @local.name, card["group_name"]
    assert_not card["user"].key?("email")
  end

  test "following feed is chronological across cities and discover feed stays local" do
    category = create_category(group: @remote)
    post = create_topic(category: category, user: @friend)
    Follow.create!(user: @viewer, target: @friend, status: "active")
    get "/api/v1/discovery/community", params: {scope: "following"}, headers: auth_headers(@viewer)
    assert_equal [post.id], json_response["topics"].map { |t| t["id"] }
    get "/api/v1/discovery/community", headers: auth_headers(@viewer)
    assert_empty json_response["topics"]
  end

  test "people include contributors with a common node and exclude followed or hidden accounts" do
    category = create_category(group: @local)
    create_topic(category: category, user: @friend)
    other = create_user
    create_topic(category: category, user: other)
    private_user = create_user(data: {visibility: "private"})
    create_topic(category: category, user: private_user)
    create_membership(group: @local, user: @viewer)
    create_membership(group: @local, user: @friend)
    get "/api/v1/discovery/community", headers: auth_headers(@viewer)
    assert_equal @friend.id, json_response["people"].first["id"]
    assert_equal "与你在同一个群组", json_response["people"].first["recommendation_reason"]
    assert_not json_response["people"].any? { |u| u["id"] == private_user.id }
    Follow.create!(user: @viewer, target: @friend, status: "active")
    get "/api/v1/discovery/community", headers: auth_headers(@viewer)
    assert_not json_response["people"].any? { |u| u["id"] == @friend.id }
  end

  test "signed cursor is stable, scoped to viewer and city, and rechecks visibility" do
    6.times { |i| event(start_time: @now+(i+1).days, end_time: @now+(i+1).days+1.hour) }
    get "/api/v1/discovery/feed", params: {kind: "events", limit: 2}, headers: auth_headers(@viewer)
    assert_response :success
    first = json_response
    assert first["next_cursor"]
    get "/api/v1/discovery/feed", params: {kind: "events", limit: 2, cursor: first["next_cursor"]}, headers: auth_headers(@viewer)
    assert_response :success
    assert_empty first["data"].map { |e| e["id"] } & json_response["data"].map { |e| e["id"] }
    get "/api/v1/discovery/feed", params: {kind: "events", cursor: first["next_cursor"], city: "杭州"}, headers: auth_headers(@viewer)
    assert_response :unprocessable_entity
    get "/api/v1/discovery/feed", params: {kind: "events", cursor: first["next_cursor"]}, headers: auth_headers(@friend)
    assert_response :unprocessable_entity
  end

  test "cached candidate IDs are reauthorized after publication or board changes" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stub(:cache, cache) do
      visible = event
      get "/api/v1/discovery/home"
      assert json_response["events"].any? { |row| row["id"] == visible.id }
      visible.update!(visibility: "unlisted")
      get "/api/v1/discovery/home"
      assert_empty json_response["events"]
    end
  end

  test "query count is bounded as cards grow and small cards do not load entire bodies" do
    category = create_category(group: @local)
    24.times do
      event
      create_topic(category: category, user: @friend)
    end
    count = 0
    callback = ->(_name, _start, _finish, _id, payload) { count += 1 if payload[:sql].match?(/\ASELECT/i) && payload[:name] != "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get "/api/v1/discovery/community", headers: auth_headers(@viewer)
    end
    assert_response :success
    assert_operator count, :<=, 35, "community SELECT count: #{count}"
    puts "Discovery community SQL queries (24 cards): #{count}"
    count = 0
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get "/api/v1/discovery/home", headers: auth_headers(@viewer)
    end
    assert_operator count, :<=, 35, "home SELECT count: #{count}"
    puts "Discovery home SQL queries (24 cards): #{count}"
    assert_operator json_response["events"].size, :<=, 12
  end
  test "derived city and public activity signal follow edits and removed content" do
    category = create_category(group: @local)
    post = create_topic(category: category, user: @friend)
    assert_equal post.created_at.to_i, @local.reload.discovery_active_at.to_i
    post.soft_delete!(by: @friend)
    assert_nil @local.reload.discovery_active_at
    @local.update!(city: "Hangzhou")
    assert_equal "杭州", @local.reload.browse_city
    get "/api/v1/discovery/home", params: {city: "杭州"}
    assert json_response["groups"].any? { |g| g["id"] == @local.id }
  end

  test "shared cache cannot mix personal agendas between accounts" do
    cache = ActiveSupport::Cache::MemoryStore.new
    booked = event
    Participant.create!(event: booked, user: @viewer, status: "attending")
    Rails.stub(:cache, cache) do
      get "/api/v1/discovery/home", headers: auth_headers(@viewer)
      assert_equal [booked.id], json_response["upcoming"].map { |e| e["id"] }
      assert_equal "private, no-store", response.headers["Cache-Control"]
      get "/api/v1/discovery/home", headers: auth_headers(@friend)
      assert_empty json_response["upcoming"]
      assert_equal [booked.id], json_response["events"].map { |e| e["id"] }
    end
  end

  test "first screen preserves alternatives instead of one node occupying all cards" do
    another = create_group(city: "上海")
    4.times { |i| event(start_time: @now+(i+1).hours, end_time: @now+(i+2).hours) }
    alternative = event(group: another, start_time: @now+1.day, end_time: @now+1.day+1.hour)
    get "/api/v1/discovery/home", headers: auth_headers(@viewer)
    assert_equal alternative.id, json_response["events"][2]["id"]
    assert_equal 5, json_response["events"].length
  end

  test "old campaign with an earlier upcoming event precedes newly created later campaigns" do
    soon = event
    later = event(start_time: @now+5.days, end_time: @now+5.days+1.hour)
    first = Campaign.create!(owner: @owner, group: @local, title: "马上开始的老专题", introduction: "介绍", status: "published", created_at: 1.year.ago)
    second = Campaign.create!(owner: @owner, group: @local, title: "刚创建的专题", introduction: "介绍", status: "published")
    CampaignEvent.create!(campaign: first, event: soon)
    CampaignEvent.create!(campaign: second, event: later)
    get "/api/v1/discovery/home"
    assert_equal [first.id, second.id], json_response["campaigns"].map { |c| c["id"] }
    assert_equal 1, json_response["campaigns"].first["event_count"]
  end

end
