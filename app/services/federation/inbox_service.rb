module Federation
  # Business processing of a signature-verified inbound activity. Identity is
  # the verified fed_actor — never the payload's own actor claim (the
  # controller already rejected mismatches). Phase 2 handles Follow and
  # Undo(Follow); everything else is ignored with a log line (Mastodon-style
  # silent drop). Join/Note land in Phase 3.
  class InboxService
    def self.process(fed_actor, activity)
      case activity["type"]
      when "Follow" then handle_follow(fed_actor, activity)
      when "Undo" then handle_undo(fed_actor, activity)
      else
        Logging.log(:in, activity["type"], domain: fed_actor.domain, status: "ignored")
        :ignored
      end
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
