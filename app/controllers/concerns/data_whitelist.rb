module DataWhitelist
  BOOLEAN_DATA_KEYS = %w[share_activity onboarded allow_event_requests].freeze

  def merge_whitelisted_data(record, raw, keys)
    return nil if raw.nil?

    incoming = raw.permit(keys).to_h.deep_stringify_keys
    BOOLEAN_DATA_KEYS.each do |key|
      incoming[key] = ActiveModel::Type::Boolean.new.cast(incoming[key]) if incoming.key?(key)
    end
    if incoming["contact"].is_a?(Hash)
      incoming["contact"] = (record.data["contact"] || {}).stringify_keys.merge(incoming["contact"])
    end
    (record.data || {}).stringify_keys.merge(incoming)
  end
end
