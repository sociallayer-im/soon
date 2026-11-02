# Shared city normalization and selectable city catalogue.
class DiscoveryCity
  ALIASES = {"shanghai"=>"上海", "beijing"=>"北京", "hangzhou"=>"杭州", "shenzhen"=>"深圳", "guangzhou"=>"广州", "chengdu"=>"成都", "dali"=>"大理"}.freeze
  # Product-maintained catalogue, independent of free-form legacy Group cities.
  OPTIONS = %w[上海 杭州 深圳 成都].freeze

  def self.options
    OPTIONS.dup
  end

  def self.normalize(value)
    city = value.to_s.strip.downcase.sub(/市\z/, "")
    ALIASES.fetch(city, city).presence
  end
end
