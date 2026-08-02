module Federation
  # Business processing of a signature-verified inbound activity. Identity is
  # the verified fed_actor — never the payload's own actor claim (the
  # controller already rejected mismatches). Anything unhandled is dropped with
  # a log line rather than an error, the same silent discard Mastodon does, so
  # a peer's unsupported vocabulary never looks like a delivery failure.
  class InboxService
    def self.process(fed_actor, activity)
      case activity["type"]
      when "Follow" then handle_follow(fed_actor, activity)
      when "Undo" then handle_undo(fed_actor, activity)
      when "Join" then ParticipationService.join(fed_actor, activity)
      when "Leave" then ParticipationService.leave(fed_actor, activity)
      when "Create" then handle_create(fed_actor, activity)
      when "Update" then handle_update(fed_actor, activity)
      when "Delete" then handle_delete(fed_actor, activity)
      when "Accept" then handle_accept(fed_actor, activity)
      when "Reject" then handle_reject(fed_actor, activity)
      else
        Logging.log(:in, activity["type"], domain: fed_actor.domain, status: "ignored")
        :ignored
      end
    end

    # --- outbound-side responses ---------------------------------------------

    # Accept resolves one of our own outbound activities: a Follow we sent, or
    # a Join. Peers echo the original activity (inline or by uri), which is why
    # we stored its id.
    def self.handle_accept(fed_actor, activity)
      uri = object_uri(activity["object"])
      return :ignored if uri.blank?

      if (follow = FedFollow.find_by(uri: uri, direction: "outbound", fed_actor: fed_actor))
        follow.update!(state: "accepted")
        Logging.log(:in, "Accept", domain: fed_actor.domain, status: "follow_accepted")
        return :processed
      end
      if (part = FedParticipation.find_by(uri: uri))
        # only the instance owning the event may approve a participation
        return :ignored unless part.fed_event.fed_actor_id == fed_actor.id
        part.update!(status: "attending")
        Logging.log(:in, "Accept", domain: fed_actor.domain, status: "join_accepted")
        return :processed
      end
      Logging.log(:in, "Accept", domain: fed_actor.domain, status: "no_match")
      :ignored
    end

    def self.handle_reject(fed_actor, activity)
      uri = object_uri(activity["object"])
      return :ignored if uri.blank?

      if (follow = FedFollow.find_by(uri: uri, direction: "outbound", fed_actor: fed_actor))
        follow.update!(state: "rejected")
        Logging.log(:in, "Reject", domain: fed_actor.domain, status: "follow_rejected")
        return :processed
      end
      if (part = FedParticipation.find_by(uri: uri))
        return :ignored unless part.fed_event.fed_actor_id == fed_actor.id
        part.update!(status: "rejected")
        Logging.log(:in, "Reject", domain: fed_actor.domain, status: "join_rejected",
                    reason: activity["summary"])
        return :processed
      end
      :ignored
    end

    # Peers send Accept/Reject with the original activity either inlined or as
    # a bare uri string; both forms have to resolve to the same id.
    def self.object_uri(object)
      case object
      when String then object
      when Hash then object["id"]
      end
    end

    # --- remote content mirroring --------------------------------------------

    def self.handle_update(fed_actor, activity)
      object = activity["object"]
      if object.is_a?(Hash) && object["type"] == "Event"
        event = RemoteEventService.upsert(object, fed_actor)
        Logging.log(:in, "Update", domain: fed_actor.domain,
                    status: event ? "event_updated" : "event_rejected")
        return event ? :processed : :ignored
      end
      Logging.log(:in, "Update", domain: fed_actor.domain, status: "unsupported_object")
      :ignored
    end

    # A Delete or a Tombstone retires the mirror. Only the origin may do it —
    # the unauthenticated remote delete that nebula's inbox allowed is exactly
    # what this check prevents.
    def self.handle_delete(fed_actor, activity)
      uri = object_uri(activity["object"])
      return :ignored if uri.blank?
      event = FedEvent.find_by(uri: uri)
      if event.nil? || event.fed_actor_id != fed_actor.id
        Logging.log(:in, "Delete", domain: fed_actor.domain, status: "not_owned")
        return :ignored
      end
      event.update!(status: "CANCELLED")
      Logging.log(:in, "Delete", domain: fed_actor.domain, status: "event_cancelled")
      :processed
    end

    def self.handle_follow(fed_actor, activity)
      target = resolve_local_actor(activity["object"])
      if target.nil?
        Logging.log(:in, "Follow", domain: fed_actor.domain, status: "unknown_target")
        return :ignored
      end

      follow = FedFollow.find_or_initialize_by(local: target, fed_actor: fed_actor, direction: "inbound")
      # a repeat Follow updates the stored uri and re-Accepts (Mastodon
      # re-sends Accept for duplicate follows)
      follow.assign_attributes(uri: activity["id"], state: "accepted")
      follow.save!
      OutboxService.accept_follow(target, fed_actor, activity)
      Logging.log(:in, "Follow", domain: fed_actor.domain, status: "accepted", target: target.name)
      :accepted
    end

    def self.handle_undo(fed_actor, activity)
      object = activity["object"]
      follow =
        if object.is_a?(Hash) && object["type"] == "Follow"
          FedFollow.find_by(uri: object["id"]) ||
            begin
              target = resolve_local_actor(object["object"])
              target && FedFollow.find_by(local: target, fed_actor: fed_actor, direction: "inbound")
            end
        elsif object.is_a?(String)
          FedFollow.find_by(uri: object)
        end

      if follow.nil? || follow.fed_actor_id != fed_actor.id
        Logging.log(:in, "Undo", domain: fed_actor.domain, status: "no_matching_follow")
        return :ignored
      end
      follow.destroy!
      Logging.log(:in, "Undo", domain: fed_actor.domain, status: "unfollowed")
      :processed
    end

    # Create(Note) with inReplyTo pointing at one of our events becomes an
    # event comment — the mechanism that makes Mastodon replies show up on
    # the event page (Mobilizon comment.ex:156-201 does the same).
    def self.handle_create(fed_actor, activity)
      object = activity["object"]
      if object.is_a?(Hash) && object["type"] == "Event"
        event = RemoteEventService.upsert(object, fed_actor)
        Logging.log(:in, "Create", domain: fed_actor.domain,
                    status: event ? "event_mirrored" : "event_rejected")
        return event ? :processed : :ignored
      end
      unless object.is_a?(Hash) && object["type"] == "Note"
        Logging.log(:in, "Create", domain: fed_actor.domain, status: "unsupported_object")
        return :ignored
      end
      event = ParticipationService.resolve_event(object["inReplyTo"])
      parent = Comment.find_by(fed_uri: object["inReplyTo"]) ||
               local_comment_from_uri(object["inReplyTo"])
      event ||= parent&.item if parent&.item_type == "Event"
      if event.nil?
        Logging.log(:in, "Create", domain: fed_actor.domain, status: "no_local_parent")
        return :ignored
      end

      return :ignored if object["id"].blank? || Comment.exists?(fed_uri: object["id"])
      Comment.create!(
        item: event, comment_type: "comment", content_type: "html",
        content: ActionController::Base.helpers.sanitize(object["content"].to_s),
        fed_actor_id: fed_actor.id, fed_uri: object["id"],
        reply_parent_id: parent&.id
      )
      Logging.log(:in, "Create", domain: fed_actor.domain, status: "comment", event: event.id)
      :processed
    end

    def self.local_comment_from_uri(uri)
      return nil unless uri.is_a?(String) && Urls.local?(uri)
      id = URI.parse(uri).path[%r{\A/comments/(.+)\z}, 1]
      id && Comment.find_by(id: id)
    rescue URI::Error
      nil
    end

    def self.resolve_local_actor(uri)
      return nil unless uri.is_a?(String) && Urls.local?(uri)
      case URI.parse(uri).path
      when %r{\A/users/(?<name>[a-z0-9_]+)\z} then User.find_by(name: Regexp.last_match[:name])
      when %r{\A/groups/(?<name>[a-z0-9_-]+)\z} then Group.find_by(name: Regexp.last_match[:name])
      end
    rescue URI::Error
      nil
    end
  end
end
