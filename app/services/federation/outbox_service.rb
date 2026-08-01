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
