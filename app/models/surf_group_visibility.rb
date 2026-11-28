class SurfGroupVisibility < ActiveSupport::CurrentAttributes
  attribute :group_ids

  def self.cache_key
    group_ids ? "surf-#{group_ids.join(',')}" : "main"
  end

  def self.for_request(request)
    hosts = [request.get_header("HTTP_HOST").to_s.split(":").first, request.host]
    return unless hosts.any? { |host| host.to_s.downcase.delete_suffix(".") == "surf.soda.fan" }

    ENV.fetch("SURF_GROUP_IDS", "").split(/[\s,]+/).reject(&:empty?).uniq.sort
  end
end
