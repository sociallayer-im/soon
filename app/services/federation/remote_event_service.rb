module Federation
  # Normalizes an inbound AS2 Event into the local mirror. Parsing is
  # deliberately forgiving in the same places Mobilizon is (converter/
  # address.ex tolerates a Place with no type and no address; non-float
  # coordinates are dropped rather than failing the whole object), because a
  # strict parser turns a cosmetic difference into a dropped event.
  class RemoteEventService
    def self.upsert(object, fed_actor)
      return nil unless object.is_a?(Hash) && object["type"] == "Event"
      uri = object["id"]
      return nil unless uri.is_a?(String) && uri.start_with?("https://", "http://")
      # the object must come from the actor that sent it
      return nil unless same_origin?(uri, fed_actor&.uri)

      place = object["location"].is_a?(Hash) ? object["location"] : {}
      address = place["address"].is_a?(Hash) ? place["address"] : {}

      event = FedEvent.find_or_initialize_by(uri: uri)
      event.assign_attributes(
        fed_actor_id: fed_actor&.id,
        title: object["name"].to_s.presence,
        content: sanitize(object["content"]),
        summary: object["summary"].to_s.presence,
        start_time: parse_time(object["startTime"]),
        end_time: parse_time(object["endTime"]),
        timezone: object["timezone"].presence,
        status: normalize_status(object),
        join_mode: %w[free restricted invite external].include?(object["joinMode"]) ? object["joinMode"] : "free",
        external_participation_url: http_url(object["externalParticipationUrl"]),
        max_participant: positive_int(object["maximumAttendeeCapacity"]),
        participant_count: positive_int(object["participantCount"]) || 0,
        location_name: place["name"].to_s.presence,
        address: address["streetAddress"].to_s.presence,
        latitude: coordinate(place["latitude"], 90),
        longitude: coordinate(place["longitude"], 180),
        image_url: banner_url(object["attachment"]),
        html_url: http_url(object["url"]) || uri,
        tags: hashtags(object["tag"]),
        raw: object,
        last_fetched_at: Time.current
      )
      event.save!
      event
    rescue ActiveRecord::RecordNotUnique
      FedEvent.find_by(uri: uri)
    end

    def self.same_origin?(uri, actor_uri)
      return false if actor_uri.blank?
      URI.parse(uri).host == URI.parse(actor_uri).host
    rescue URI::Error
      false
    end

    def self.normalize_status(object)
      raw = (object["status"] || object["ical:status"]).to_s.upcase
      %w[CONFIRMED CANCELLED TENTATIVE].include?(raw) ? raw : "CONFIRMED"
    end

    def self.parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Mobilizon drops coordinates that are not floats rather than rejecting the
    # object; do the same, and reject out-of-range values too.
    def self.coordinate(value, bound)
      return nil unless value.is_a?(Numeric)
      f = value.to_f
      f.abs <= bound ? f : nil
    end

    def self.positive_int(value)
      return nil unless value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)
      i = value.to_i
      i >= 0 ? i : nil
    end

    def self.http_url(value)
      value.to_s if value.is_a?(String) && value.start_with?("https://", "http://")
    end

    def self.banner_url(attachments)
      Array(attachments).find { |a|
        a.is_a?(Hash) && a["type"] == "Image" && http_url(a["url"])
      }&.dig("url")
    end

    def self.hashtags(tags)
      Array(tags).filter_map { |t|
        next unless t.is_a?(Hash) && t["type"] == "Hashtag"
        t["name"].to_s.delete_prefix("#").presence
      }
    end

    def self.sanitize(html)
      return nil if html.blank?
      ActionController::Base.helpers.sanitize(html.to_s)
    end
  end
end
