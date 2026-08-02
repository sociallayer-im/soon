module Federation
  # Builds outbound activities and writes fed_deliveries rows — inside the
  # caller's transaction when there is one (outbox pattern). Never performs
  # HTTP; the sweeper/delivery jobs drain the queue.
  class OutboxService
    # Accept echoes the remote Follow verbatim as its object — Mastodon
    # matches the Accept by that inner id.
    def self.accept_follow(local_actor, fed_actor, follow_activity)
      follow = FedFollow.find_by!(uri: follow_activity["id"])
      payload = {
        "@context" => JsonLd::AS,
        "id" => Urls.activity_url("accept/follow/#{follow.id}"),
        "type" => "Accept",
        "actor" => Urls.actor_url(local_actor),
        "object" => follow_activity,
        "to" => [fed_actor.uri]
      }
      enqueue(payload, sender: local_actor, inboxes: [fed_actor.delivery_inbox_url])
    end

    # Accept(Join): object is the inlined Join, id path mirrors Mobilizon's
    # "<endpoint>/accept/join/<participant_id>" so peers see a familiar shape.
    def self.accept_join(event, fed_actor, join_activity, participant)
      payload = {
        "@context" => JsonLd::AS,
        "id" => Urls.activity_url("accept/join/#{participant.id}"),
        "type" => "Accept",
        "actor" => Urls.actor_url(event.group),
        "attributedTo" => Urls.actor_url(event.group),
        "object" => join_activity,
        "to" => [fed_actor.uri]
      }
      enqueue(payload, sender: event.group, inboxes: [fed_actor.delivery_inbox_url])
    end

    def self.reject_join(event, fed_actor, join_activity, reason: nil)
      payload = {
        "@context" => JsonLd::AS,
        "id" => Urls.activity_url("reject/join/#{SecureRandom.hex(8)}"),
        "type" => "Reject",
        "actor" => Urls.actor_url(event.group),
        "attributedTo" => Urls.actor_url(event.group),
        "object" => join_activity,
        "to" => [fed_actor.uri]
      }
      payload["summary"] = reason if reason
      enqueue(payload, sender: event.group, inboxes: [fed_actor.delivery_inbox_url])
    end

    # Note in reply to an event — how comments federate to and from Mastodon
    # (Mobilizon converter/comment.ex:98-127).
    def self.publish_comment(comment, event)
      return unless Federation.enabled?
      inboxes = event_audience_inboxes(event)
      return if inboxes.empty?
      # The signing key must belong to the actor the activity claims, or
      # Mastodon drops it before ever looking at the object (it only accepts a
      # mismatch when an LD signature re-attributes it, which we do not emit).
      # A commenter without a handle has no actor of their own, so the group
      # both signs and owns the note.
      serializer = CommentSerializer.new(comment, event)
      sender = serializer.author_actor
      actor_url = Urls.actor_url(sender)
      note = serializer.as_ap(context: false)
      activity = {
        "@context" => JsonLd.context,
        "id" => "#{note['id']}/activity",
        "type" => "Create",
        "actor" => actor_url,
        "to" => note["to"],
        "cc" => note["cc"],
        "object" => note
      }
      enqueue(activity, sender: sender, inboxes: inboxes)
    end

    # verb: :create | :update | :delete. Serializes once, fans out to the
    # group's followers (plus the owner's, deduped by inbox).
    def self.publish_event(event, verb)
      return unless Federation.enabled?
      inboxes = event_audience_inboxes(event)
      return if inboxes.empty?

      activity =
        if verb == :delete
          tombstone_activity(event)
        else
          object = EventSerializer.new(event).as_ap
          {
            "@context" => JsonLd.context,
            "id" => "#{Urls.event_url(event)}/activity/#{verb}-#{event.updated_at.to_i}",
            "type" => verb == :create ? "Create" : "Update",
            "actor" => object["attributedTo"],
            "to" => object["to"],
            "cc" => object["cc"],
            "object" => object.except("@context")
          }
        end

      enqueue(activity, sender: event.group, inboxes: inboxes)
      Logging.log(:out, activity["type"], status: "queued", inboxes: inboxes.size, event: event.id)
    end

    def self.tombstone_activity(event)
      uri = Urls.event_url(event)
      {
        "@context" => JsonLd::AS,
        "id" => "#{uri}/activity/delete-#{Time.current.to_i}",
        "type" => "Delete",
        "actor" => Urls.actor_url(event.group),
        "to" => [JsonLd::PUBLIC],
        "object" => {"type" => "Tombstone", "id" => uri}
      }
    end

    # Distinct allowed inboxes across the group's and owner's followers.
    # Domain filtering happens here (not at delivery time) so blocked or
    # long-unavailable domains never even enqueue.
    def self.event_audience_inboxes(event)
      followers = FedFollow.accepted.inbound.where(local: event.group)
      if event.owner&.name.present?
        followers = followers.or(FedFollow.accepted.inbound.where(local: event.owner))
      end
      actors = FedActor.where(id: followers.select(:fed_actor_id), blocked_at: nil)
      actors.filter_map { |actor|
        next unless FedDomainPolicy.domain_allowed?(actor.domain)
        next if FedDomainStat.unavailable?(actor.domain)
        actor.delivery_inbox_url
      }.uniq
    end

    def self.enqueue(payload, sender:, inboxes:)
      rows = inboxes.map { |inbox|
        FedDelivery.create!(payload: payload, sender_type: sender.class.name,
                            sender_id: sender.id, inbox_url: inbox)
      }
      # after_commit so the sweeper never races an uncommitted row
      ActiveRecord::Base.current_transaction.after_commit { Federation::SweeperJob.perform_later }
      rows
    end
  end
end
