# Derived from Group#city; the original city remains the source of truth.
class DiscoveryCity
  ALIASES = {"shanghai"=>"上海", "beijing"=>"北京", "hangzhou"=>"杭州", "shenzhen"=>"深圳", "guangzhou"=>"广州", "chengdu"=>"成都", "dali"=>"大理"}.freeze
  def self.normalize(value)
    city = value.to_s.strip.downcase.sub(/市\z/, "")
    ALIASES.fetch(city, city).presence
  end
end
