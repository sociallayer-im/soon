# Explicit, idempotent content maintenance. Never part of db:seed or deployment.
# Requires SURF_FIXTURE_BACKUP and SURF_FIXTURE_ASSETS; targets marked fixtures only.
require "json"
require "fileutils"
raise "Set SURF_APPLY_FIXTURES=1" unless ENV["SURF_APPLY_FIXTURES"] == "1"
backup_path = ENV.fetch("SURF_FIXTURE_BACKUP")
asset_dir = ENV.fetch("SURF_FIXTURE_ASSETS")
groups = Group.where(name: %w[surf-demo-city surf-demo-makers]).to_a
raise "Expected two fixture groups" unless groups.size == 2 && groups.all? { |g| g.data["surf_demo"] == true }
group = groups.find { |g| g.name == "surf-demo-city" }
raise "Shanghai fixture group must already be approved" unless group.city == "上海" && group.active? && group.review_status == "approved"
users = User.where(name: %w[lin summer chen momo iris river].map { |n| "surf-demo-#{n}" }).to_a
raise "Expected six fixture users" unless users.size == 6 && users.all? { |u| u.data["surf_demo"] == true }
owner = group.memberships.find_by!(role: "owner").user
fixture_events = Event.where(group_id: groups.map(&:id)).where("slug LIKE ?", "surf-demo-%").to_a
fixture_topics = Topic.where(group_id: groups.map(&:id), user_id: users.map(&:id)).to_a
fixture_replies = Reply.where(topic_id: fixture_topics.map(&:id)).to_a
fixture_campaigns = Campaign.where(group_id: groups.map(&:id)).where("title LIKE ?", "%演示%").to_a
fixture_categories = Category.where(group_id: groups.map(&:id), slug: "surf-demo-lounge").to_a
fixture_places = Place.where(id: fixture_events.map(&:place_id).compact).to_a
fields = {
  "Group" => %w[nickname bio image_url logo_url featured_image_url banner_image_url],
  "User" => %w[nickname bio image_url], "Event" => %w[title content image_url tags],
  "Topic" => %w[title content image_url tags], "Reply" => %w[content],
  "Category" => %w[name summary], "Campaign" => %w[title introduction kicker cover_url media], "Place" => %w[name address description]
}
records = groups + users + fixture_events + fixture_topics + fixture_replies + fixture_campaigns + fixture_places + fixture_categories
raise "Backup already exists; use a fresh backup path" if File.exist?(backup_path)
File.write(backup_path, JSON.pretty_generate(records.map { |r| {model: r.class.name, id: r.id, attributes: r.attributes.slice(*fields.fetch(r.class.name))} }), mode: "wx", perm: 0600)
assets = %w[c5d06 5c017 bce89 f7270 6c975 d3302 c8146].to_h do |key|
  url = File.open(File.join(asset_dir, "#{key}.png"), "rb") { |io| ObjectStore.upload(io: io, content_type: "image/png") }
  [key, url]
end
clean_text = ->(value) { value.gsub(/（演示(?:专题|地点|回复)?）/, "").gsub("演示", "体验").gsub("Surf", "Sola") }
clean_value = nil
clean_value = ->(value) do
  case value
  when String
    key = value[%r{\Ahttps://surf\.generic\.dev/assets/([a-z0-9]+)\.png\z}, 1]
    key && assets[key] ? assets.fetch(key) : clean_text.call(value)
  when Array then value.map { |v| clean_value.call(v) }
  when Hash then value.transform_values { |v| clean_value.call(v) }
  else value
  end
end
manifest = []
ApplicationRecord.transaction do
  records.each do |record|
    changes = record.attributes.slice(*fields.fetch(record.class.name)).transform_values { |v| clean_value.call(v) }
    record.skip_site_notification = true if record.respond_to?(:skip_site_notification=)
    record.update!(changes)
  end
  [
    ["2026-11-06", 19, "coffee", "周五咖啡小聚", "c5d06", "meetup", "聊聊本周的新发现，认识一起探索城市的朋友。"],
    ["2026-11-07", 14, "walk", "周末街区摄影散步", "5c017", "meetup", "沿着街区慢慢走，用手机或相机记录日常风景。"],
    ["2026-11-08", 10, "reading", "周日河畔读书会", "bce89", "meetup", "带一本最近在读的书，分享一个喜欢的片段。"]
  ].each do |date, hour, suffix, title, image, kind, introduction|
    start_time = Time.find_zone!("Asia/Shanghai").parse("#{date} #{hour}:00:00")
    slug = "sola-week-#{date.delete('-')}-#{suffix}"
    event = Event.find_or_initialize_by(group: group, slug: slug)
    raise "Fixture slug collision" if event.persisted? && event.owner_id != owner.id
    place = Place.find_or_create_by!(name: "上海 · 集合地点待确认") do |p|
      p.address = "上海，具体地点待主办方确认"
      p.description = "页面体验用活动，暂不组织线下集合，请勿直接前往。"
    end
    event.skip_site_notification = true
    event.assign_attributes(title: title, owner: owner, place: place, start_time: start_time, end_time: start_time + 2.hours,
      timezone: "Asia/Shanghai", status: "published", visibility: "open_registration", image_url: assets.fetch(image),
      kind: kind, max_participant: 20, require_approval: false, tags: ["城市生活"],
      content: "## #{title}\n\n#{introduction}\n\n### 活动安排\n- 自我介绍与自由交流\n- 主题分享与互动\n- 记录收获，交流下一次的想法\n\n### 参与说明\n免费，20 个名额。这是用于体验活动列表、报名和日历的活动，暂不组织线下集合；正式安排以主办方后续确认为准。")
    event.save!
    ticket = event.tickets.find_or_initialize_by(title: "免费参与")
    ticket.assign_attributes(status: "normal", ticket_type: "event", group_id: group.id, quantity: 20, need_approval: false) if ticket.new_record?
    ticket.save!
    EventRole.find_or_create_by!(event: event, item: group, role: "group_host")
    manifest << {id: event.id, title: event.title, start: event.local_start.iso8601, end: event.local_end.iso8601, city: group.city, image: event.image_url}
  end
  group.update!(events_count: group.events.count)
end
puts JSON.pretty_generate({cleaned_records: records.size, events: manifest, backup: backup_path})
