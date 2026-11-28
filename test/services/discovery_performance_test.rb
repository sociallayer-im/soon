require "test_helper"

class DiscoveryPerformanceTest < ActiveSupport::TestCase
  test "planner uses the partial time index with thousands of historical activities" do
    owner = create_user
    group = create_group(owner: owner, city: "上海")
    now = Time.current
    rows = 6000.times.map do |i|
      at = i < 5800 ? now - (i+2).days : now + (i-5799).hours
      {id: "plan-#{SecureRandom.hex(10)}", title: "查询计划样本", group_id: group.id, owner_id: owner.id,
       start_time: at, end_time: at+1.hour, created_at: now, updated_at: now, status: "published", visibility: "normal"}
    end
    Event.insert_all!(rows)
    Event.connection.execute("ANALYZE events")
    sql = DiscoveryFeed.new(user: nil, city: "上海").public_events.where("start_time >= ?", now).order(:start_time, :id).limit(120).select(:id).to_sql
    raw = Event.connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}")
    plan = JSON.parse(raw)
    text = plan.to_json
    assert_match(/idx_events_discovery_(start|group_start|end)/, text)
    puts "Discovery plan (6000 events): #{plan.first['Execution Time']}ms; index=#{text.scan(/idx_events_discovery_[a-z_]+/).uniq.join(',')}; shared_hits=#{plan.first.dig('Plan','Shared Hit Blocks')}"
  end
  test "public post feed uses the created-time index with thousands of posts" do
    old = ENV["DISCUSSION_ENABLED"]
    ENV["DISCUSSION_ENABLED"] = "true"
    owner = create_user
    group = create_group(city: "上海")
    category = create_category(group: group)
    now = Time.current
    Topic.insert_all!(6000.times.map do |i|
      {id: "post-plan-#{SecureRandom.hex(8)}", group_id: group.id, category_id: category.id, user_id: owner.id,
       title: "查询计划样本", content: "正文", created_at: now-i.minutes, updated_at: now, last_active_mark: now.to_i-i*60, sync_to_community: true}
    end)
    %w[topics groups categories].each { |table| Topic.connection.execute("ANALYZE #{table}") }
    sql = DiscoveryFeed.new(user: nil, city: "上海").public_topics.order(created_at: :desc, id: :desc).limit(120).select(:id).to_sql
    plan = JSON.parse(Topic.connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}"))
    assert_match(/idx_topics_discovery_(created|group_created)/, plan.to_json)
    puts "Discovery plan (6000 posts): #{plan.first['Execution Time']}ms; index=#{plan.to_json.scan(/idx_topics_discovery_[a-z_]+/).uniq.join(',')}; shared_hits=#{plan.first.dig('Plan','Shared Hit Blocks')}"
  ensure
    ENV["DISCUSSION_ENABLED"] = old
  end

end
