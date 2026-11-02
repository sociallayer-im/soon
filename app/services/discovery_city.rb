# Derived from Group#city; the original city remains the source of truth.
class DiscoveryCity
  ALIASES = {"shanghai"=>"上海", "beijing"=>"北京", "hangzhou"=>"杭州", "shenzhen"=>"深圳", "guangzhou"=>"广州", "chengdu"=>"成都", "dali"=>"大理"}.freeze
  # One canonical catalogue for discovery, calendar and group city selectors.
  def self.options
    Rails.cache.fetch("discovery-cities-v2", expires_in: 1.minute, race_condition_ttl: 5.seconds) do
      Group.where(active: true, review_status: "approved").where.not(browse_city: [nil, ""]).distinct.order(:browse_city).pluck(:browse_city)
    end
  end

  def self.normalize(value)
    city = value.to_s.strip.downcase.sub(/市\z/, "")
    ALIASES.fetch(city, city).presence
  end
end
