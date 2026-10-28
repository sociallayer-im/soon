# Run explicitly with bin/rails runner script/seed_surf_demo.rb (never db:seed).
# Stable handles/slugs make repeated runs idempotent; existing real data is untouched.
require "json"
raise "This fixture is only for soon_atlas" unless ActiveRecord::Base.connection_db_config.database == "soon_atlas"
asset = ->(file) { "https://surf.generic.dev/assets/#{file}.png" }
manifest = {}
ApplicationRecord.transaction do
  users = %w[lin summer chen momo iris river].each_with_index.map do |handle, i|
    u = User.find_or_initialize_by(name: "surf-demo-#{handle}")
    raise "Handle collision" if u.persisted? && u.email != "#{handle}@surf-demo.invalid"
    u.assign_attributes(email: "#{handle}@surf-demo.invalid", nickname: ["林间", "夏天", "阿辰", "墨墨", "小鸢", "川流"][i] + "（演示）",
      bio: ["喜欢街头摄影和城市散步", "用咖啡串联城市里的朋友", "独立开发者，热爱分享", "用设计记录日常灵感", "周末读书与手作爱好者", "寻找自然与生活的连接"][i] + "。Surf 虚拟演示用户。",
      image_url: asset.call(i.even? ? "6c975" : "d3302"), active: true, data: {surf_demo: true})
    u.save!
    u
  end
  specs = [
    ["surf-demo-city", "Surf 城市漫游（演示）", "一起发现城市的街角、公园和咖啡馆。这里有摄影散步、周末野餐和轻松交流。所有内容均为演示数据。", "c5d06", "上海", ["周末梧桐街区摄影漫步", "河畔日落野餐与读书会", "街角咖啡与新朋友见面会"], ["分享你最喜欢的一条散步路线", "本周随手拍：城市里的秋天", "新朋友报到，一起发现身边的小店"]],
    ["surf-demo-makers", "Surf 灵感共创（演示）", "面向设计师、开发者与创作者的友好社区。分享作品、交流想法，让灵感在真实的相遇中发生。所有内容均为演示数据。", "f7270", "杭州", ["周末独立开发者共创日", "设计灵感分享与作品交流", "从一个想法到第一个原型"], ["你最近在做什么有趣的小项目？", "作品分享：给日常留一点设计感", "共创招募：把周末灵感变成小工具"]]
  ]
  groups = specs.each_with_index.map do |(handle, label, bio, image, city, event_titles, topic_titles), gi|
    g = Group.find_or_initialize_by(name: handle)
    raise "Group collision" if g.persisted? && g.data["surf_demo"] != true
    g.assign_attributes(nickname: label, bio: bio, location: city, timezone: "Asia/Shanghai", active: true,
      image_url: asset.call(image), logo_url: asset.call("c8146"), featured_image_url: asset.call(image), banner_image_url: asset.call(image),
      group_tags: %w[pin featured], discussion_enabled: true, can_post_topic: "member", data: {surf_demo: true})
    g.save!
    users.each_with_index { |u, i| g.add_member(u.id, i == gi ? "owner" : "member") }
    board = Category.find_or_initialize_by(group: g, slug: "surf-demo-lounge")
    board.assign_attributes(name: "社区交流", summary: "欢迎分享日常、作品和活动想法（演示）", visibility: "public")
    board.save!
    topic_titles.each_with_index do |title, i|
      t = Topic.find_or_initialize_by(group: g, category: board, title: "#{title}（演示）")
      t.assign_attributes(user: users[(i + gi) % 6], content_type: "markdown", image_url: asset.call(i == 1 ? "5c017" : image), tags: ["演示", "社区交流"],
        content: "这是 Surf 的演示帖子，用于体验社区讨论。\n\n#{gi.zero? ? '想收集适合周末散步、拍照和休息的地方。你会推荐哪条路线？欢迎分享沿途的小店和风景。' : '最近我们在尝试把日常观察变成有趣的小作品。欢迎分享你的项目进度、设计草图，或者一个还没有开始的想法。'}\n\n欢迎在下方留言，一起交流。")
      t.save!
      2.times do |ri|
        reply = Reply.find_or_initialize_by(topic: t, user: users[(i + ri + 2) % 6], content: ["很喜欢这个想法！下次活动一起交流。（演示回复）", "已收藏，期待看到更多分享。（演示回复）"][ri])
        reply.save!
      end
    end
    event_titles.each_with_index do |title, i|
      slug = "surf-demo-#{gi}-#{i}"
      e = Event.find_or_initialize_by(group: g, slug: slug)
      # Preserve dates on rerun; refresh expired fixtures so discovery stays useful.
      start = e.start_time && e.end_time.future? ? e.start_time : (Time.current.in_time_zone("Asia/Shanghai").beginning_of_day + (i + 1).days + (gi.zero? ? 14 : 10).hours)
      place = Place.find_or_initialize_by(name: "#{city} · Surf #{gi.zero? ? '城市漫游' : '共创空间'}（演示地点）")
      place.assign_attributes(address: "#{city}，具体集合地址为演示占位，非真实活动地点", description: "仅用于界面演示，请勿按此地址前往。")
      place.save!
      e.assign_attributes(title: "#{title}（演示）", owner: users[gi], place: place, start_time: start, end_time: start + 2.hours,
        timezone: "Asia/Shanghai", status: "published", visibility: "open_registration", image_url: asset.call([image, "5c017", "bce89"][i]),
        content: "## #{title}\n\n这是 Surf 功能演示活动，并非真实线下招募，请勿前往。\n\n### 活动安排\n- 开场介绍与相互认识\n- #{gi.zero? ? '街区漫步、拍照与自由交流' : '作品演示、结对共创与灵感讨论'}\n- 交流心得，记录收获\n\n### 参与方式\n免费体验报名，建议携带#{gi.zero? ? '相机或手机、饮用水' : '电脑和一个想分享的点子'}。",
        max_participant: 20, tags: ["演示", gi.zero? ? "城市漫游" : "共创"], kind: gi.zero? ? "meetup" : "workshop", require_approval: false)
      e.save!
      users.rotate(i).first(3 + i).each { |u| Participant.find_or_create_by!(event: e, user: u) { |p| p.status = "attending"; p.registered_at = Time.current } }
      e.update!(participant_count: e.participants.seated.count)
      EventRole.find_or_create_by!(event: e, item: g) { |r| r.role = "group_host" }
    end
    g.update!(events_count: g.events.count)
    {id: g.id, name: g.name, label: g.nickname, topics: g.topics.count, events: g.events.count, members: g.memberships.count}
  end
  manifest = {groups: groups, users: users.map { |u| {id: u.id, name: u.name} }}
end
puts JSON.pretty_generate(manifest)
