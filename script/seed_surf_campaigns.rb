# Explicit runner only. Never hooked into db:seed or deployment.
# Defaults for city-group/city-g are examples, not verified geographic data.
raise "Only the dedicated soon_atlas database is allowed" unless ActiveRecord::Base.connection_db_config.database == "soon_atlas"
manifest = {}
ApplicationRecord.transaction do
  cities = {"surf-demo-city" => "上海", "surf-demo-makers" => "杭州", "city-group" => "杭州", "city-g" => "上海"}
  groups = cities.map do |name, city|
    group = Group.find_by!(name: name)
    group.update!(city: city) if group.city.blank?
    {id: group.id, name: name, city: group.city}
  end
  specs = [
    ["surf-demo-city", "城市里的三次相遇（演示专题）", "从街区漫步到河畔读书，再到街角咖啡，用三次轻松相聚发现上海。", "c5d06"],
    ["surf-demo-makers", "把灵感变成作品（演示专题）", "在杭州一起分享设计、结对共创，从小想法走到第一个原型。", "f7270"]
  ]
  campaigns = specs.map do |handle, title, introduction, image|
    group = Group.find_by!(name: handle)
    raise "Not a demo group" unless group.data["surf_demo"] == true
    events = group.events.where("slug LIKE ?", "surf-demo-%").where(status: "published", visibility: %w[normal open_registration]).order(:start_time, :id).to_a
    raise "Expected three demo events" unless events.size == 3
    campaign = Campaign.find_or_initialize_by(group: group, title: title)
    campaign.assign_attributes(owner: events.first.owner, status: "published", kicker: "Surf 功能演示 · #{group.city}",
      introduction: "#{introduction}\n\n这是 Surf 功能演示专题，所含活动并非真实线下招募，请勿按演示地点前往。",
      cover_url: "https://surf.generic.dev/assets/#{image}.png",
      media: [{"type" => "image", "url" => "https://surf.generic.dev/assets/#{image}.png"}], resource_links: [])
    campaign.save!
    events.each_with_index do |event, index|
      link = campaign.campaign_events.find_or_initialize_by(event: event)
      link.update!(position: index)
    end
    {id: campaign.id, title: campaign.title, city: group.city, event_ids: campaign.event_ids}
  end
  manifest = {groups: groups, campaigns: campaigns}
end
puts JSON.pretty_generate(manifest)
