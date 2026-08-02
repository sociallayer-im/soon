module Federation
  # AS2 Event object, key-for-key aligned with Mobilizon's
  # Converter.Event.model_to_as (design/FEDERATION_PLAN.md §2.4). Only
  # public+published (or cancelled — receivers need the CANCELLED update)
  # events should reach this serializer; callers gate.
  class EventSerializer
    def initialize(event)
      @event = event
    end

    def as_ap
      doc = {
        "@context" => JsonLd.context,
        "type" => "Event",
        "id" => Urls.event_url(@event),
        "url" => Urls.event_html_url(@event),
        "name" => @event.title,
        "actor" => actor_url_for_owner,
        "attributedTo" => Urls.actor_url(@event.group),
        "content" => sanitized_content,
        "mediaType" => "text/html",
        "startTime" => @event.start_time&.utc&.iso8601,
        # Mobilizon's heuristic: never emit a nil endTime
        "endTime" => (@event.end_time || @event.start_time&.end_of_day)&.utc&.iso8601,
        "timezone" => @event.event_timezone,
        "status" => ical_status,
        "ical:status" => ical_status,
        "draft" => false,
        "joinMode" => join_mode,
        "maximumAttendeeCapacity" => @event.max_participant,
        "remainingAttendeeCapacity" => remaining_capacity,
        "participantCount" => @event.participant_count,
        "commentsEnabled" => true,
        "anonymousParticipationEnabled" => false,
        "uuid" => uuid,
        "published" => @event.created_at.utc.iso8601,
        "updated" => @event.updated_at.utc.iso8601,
        "tag" => hashtags,
        "attachment" => attachments,
        "summary" => summary
      }
      doc["externalParticipationUrl"] = Urls.event_html_url(@event) if join_mode == "external"
      doc["location"] = location if location
      doc.merge!(audience)
      # FEP-8b32: the group signs its own event object. `created` pinned to
      # updated_at makes serialization deterministic — the same content
      # always yields byte-identical proofs, so mirrors can dedupe.
      IntegrityProof.sign(doc.compact, @event.group, created: @event.updated_at)
    end

    # to/cc per Mobilizon's audience rule (audience.ex:135-138): public gets
    # as:Public in `to`; anything else inverts, followers into `to`.
    def audience
      followers = Urls.followers_url(@event.group)
      if @event.visibility == "public"
        {"to" => [JsonLd::PUBLIC], "cc" => [followers]}
      else
        {"to" => [followers], "cc" => []}
      end
    end

    UUID_RE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # Mobilizon types `uuid` as Ecto.UUID and casts it on receipt, so a value
    # that is not a UUID fails the changeset and the WHOLE event is rejected —
    # our TSID ids did exactly that, caught against a live instance. Our ids
    # are not UUIDs and inventing one would publish an identifier that
    # identifies nothing, so the field is simply omitted (as other non-Mobilizon
    # event implementations do). Receivers mint their own; `id` stays the
    # authoritative identifier and is what they match on.
    def uuid
      @event.id if @event.id.to_s.match?(UUID_RE)
    end

    def join_mode
      return "external" if @event.tickets.loaded? ? @event.tickets.any? : @event.tickets.exists?
      @event.require_approval? ? "restricted" : "free"
    end

    def ical_status
      @event.status == "cancelled" ? "CANCELLED" : "CONFIRMED"
    end

    def remaining_capacity
      return nil if @event.max_participant.blank?
      [@event.max_participant - @event.participant_count.to_i, 0].max
    end

    def location
      @location ||= begin
        place = @event.place || @event.venue&.place
        name = @event.venue&.name.presence || place&.name
        return nil if name.blank? && place.nil?
        doc = {"type" => "Place", "name" => name}
        if place
          doc["address"] = {"type" => "PostalAddress", "streetAddress" => place.address}.compact if place.address.present?
          if place.latitude.present? && place.longitude.present?
            doc["latitude"] = place.latitude.to_f
            doc["longitude"] = place.longitude.to_f
          end
        end
        doc
      end
    end

    # The one field Mastodon renders besides name and the link — a
    # human-readable "when - offset - where" line (Mobilizon event_summary/1).
    def summary
      tz = ActiveSupport::TimeZone[@event.event_timezone] || ActiveSupport::TimeZone["UTC"]
      start_local = @event.start_time&.in_time_zone(tz)
      return @event.title if start_local.nil?
      parts = [start_local.strftime("%b %-d, %Y %H:%M")]
      parts << "GMT#{start_local.formatted_offset}"
      parts << @event.location_text if @event.location_text.present?
      parts.join(" - ")
    end

    def hashtags
      Array(@event.tags).map { |t| {"type" => "Hashtag", "name" => "##{t}"} }
    end

    def attachments
      list = []
      if @event.image_url.present?
        list << {"type" => "Image", "name" => "Banner", "url" => @event.image_url}
      end
      if @event.meeting_url.present?
        list << {"type" => "Link", "name" => "Website", "href" => @event.meeting_url, "mediaType" => "text/html"}
      end
      list
    end

    def actor_url_for_owner
      owner = @event.owner
      owner&.name.present? ? Urls.actor_url(owner) : Urls.actor_url(@event.group)
    end

    def sanitized_content
      return "" if @event.content.blank?
      ActionController::Base.helpers.sanitize(@event.content)
    end
  end
end
