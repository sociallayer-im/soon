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

    # --- outbound: we are the follower / participant -------------------------

    # A local actor follows a remote one. The Follow stays pending until the
    # remote answers with an Accept naming this id, so the id has to be stable
    # and stored — but only per ATTEMPT: a rejected attempt must get a fresh
    # id, because peers dedupe on activity id and would drop a replay of the
    # rejected one forever. A still-pending attempt reuses its id (idempotent
    # resend); anything else mints a new one.
    def self.follow(local_actor, fed_actor)
      return nil unless FedDomainPolicy.domain_allowed?(fed_actor.domain)
      existing = FedFollow.find_by(local: local_actor, fed_actor: fed_actor, direction: "outbound")
      return existing if existing&.state == "accepted"

      follow = existing || FedFollow.new(local: local_actor, fed_actor: fed_actor,
                                         direction: "outbound")
      reuse = follow.persisted? && follow.state == "pending" && follow.uri.present?
      # relationship change and the owed delivery commit together (P1-2)
      ActiveRecord::Base.transaction do
        follow.assign_attributes(state: "pending",
                                 uri: reuse ? follow.uri : Urls.activity_url("follows/#{SecureRandom.uuid}"))
        follow.save!
        payload = {
          "@context" => JsonLd::AS,
          "id" => follow.uri,
          "type" => "Follow",
          "actor" => Urls.actor_url(local_actor),
          "object" => fed_actor.uri,
          "to" => [fed_actor.uri]
        }
        enqueue(payload, sender: local_actor, inboxes: [fed_actor.delivery_inbox_url])
      end
      follow
    end

    # Undo carries the full Follow inline: Mastodon's undo handler resolves the
    # target from object.object, and a bare uri only works if it recognises the
    # id (activity/undo.rb:89-130).
    def self.unfollow(local_actor, fed_actor)
      follow = FedFollow.find_by(local: local_actor, fed_actor: fed_actor, direction: "outbound")
      return nil if follow.nil?
      payload = {
        "@context" => JsonLd::AS,
        "id" => "#{follow.uri}/undo",
        "type" => "Undo",
        "actor" => Urls.actor_url(local_actor),
        "object" => {"id" => follow.uri, "type" => "Follow",
                     "actor" => Urls.actor_url(local_actor), "object" => fed_actor.uri},
        "to" => [fed_actor.uri]
      }
      ActiveRecord::Base.transaction do
        enqueue(payload, sender: local_actor, inboxes: [fed_actor.delivery_inbox_url])
        follow.destroy!
      end
      true
    end

    # Join a remote event. Only the origin instance may approve, so this stays
    # pending until its Accept arrives (Mobilizon types/events.ex:197-248).
    def self.join(user, fed_event, message: nil)
      return nil if fed_event.origin_inbox_url.blank?
      return nil unless FedDomainPolicy.domain_allowed?(fed_event.fed_actor.domain)
      part = FedParticipation.find_or_initialize_by(user: user, fed_event: fed_event)
      return part if part.persisted? && part.status == "attending"
      # a rejected/cancelled attempt needs a NEW activity id (peer dedupe);
      # a pending one resends the same id
      reuse = part.persisted? && part.status == "pending" && part.uri.present?
      ActiveRecord::Base.transaction do
        part.assign_attributes(status: "pending",
                               uri: reuse ? part.uri : Urls.activity_url("joins/#{SecureRandom.uuid}"))
        part.save!
        payload = {
          "@context" => JsonLd::AS,
          "id" => part.uri,
          "type" => "Join",
          "actor" => Urls.actor_url(user),
          "object" => fed_event.uri,
          "to" => [fed_event.fed_actor.uri]
        }
        payload["participationMessage"] = message if message.present?
        enqueue(payload, sender: user, inboxes: [fed_event.origin_inbox_url])
      end
      part
    end

    def self.leave(user, fed_event)
      part = FedParticipation.find_by(user: user, fed_event: fed_event)
      return nil if part.nil?
      payload = {
        "@context" => JsonLd::AS,
        "id" => "#{part.uri}/leave-#{SecureRandom.hex(4)}",
        "type" => "Leave",
        "actor" => Urls.actor_url(user),
        "object" => fed_event.uri,
        "to" => [fed_event.fed_actor.uri]
      }
      ActiveRecord::Base.transaction do
        enqueue(payload, sender: user, inboxes: [fed_event.origin_inbox_url])
        part.update!(status: "cancelled")
      end
      part
    end

    # A group being deleted has to be announced, or every follower keeps a
    # zombie actor and zombie events forever — there is no other signal, since
    # the actor URL simply starts 404ing. Sent before the row goes away, while
    # the followers and the signing key still exist.
    def self.delete_actor(actor)
      return unless Federation.enabled?
      inboxes = FedFollow.accepted.inbound.where(local: actor)
                         .includes(:fed_actor).filter_map { |f|
        next unless FedDomainPolicy.domain_allowed?(f.fed_actor.domain)
        f.fed_actor.delivery_inbox_url
      }.uniq
      return if inboxes.empty?

      url = Urls.actor_url(actor)
      payload = {
        "@context" => JsonLd::AS,
        "id" => "#{url}#delete",
        "type" => "Delete",
        "actor" => url,
        "to" => [JsonLd::PUBLIC],
        "object" => url
      }
      enqueue(payload, sender: actor, inboxes: inboxes)
      Logging.log(:out, "Delete", status: "actor_queued", inboxes: inboxes.size)
    end

    # Retire a single event. The normal path is a status change (an Update
    # carrying CANCELLED), which keeps the record; this is for an actual
    # destroy, where the object is about to stop existing.
    # No visibility guard here: retraction (public → private/draft) calls
    # this precisely BECAUSE the event is no longer public.
    def self.delete_event(event)
      return unless Federation.enabled?
      inboxes = event_audience_inboxes(event)
      return if inboxes.empty?
      enqueue(tombstone_activity(event), sender: event.group, inboxes: inboxes)
      Logging.log(:out, "Delete", status: "event_queued", event: event.id)
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

    # Retract a comment that was federated as a Note (P1-8): remote threads
    # keep showing it otherwise. Signed by the same actor that published it.
    def self.delete_comment(comment, event)
      return unless Federation.enabled?
      inboxes = event_audience_inboxes(event)
      return if inboxes.empty?
      serializer = CommentSerializer.new(comment, event)
      sender = serializer.author_actor
      uri = Urls.activity_url("comments/#{comment.id}") # same id the Note was published under
      payload = {
        "@context" => JsonLd::AS,
        "id" => "#{uri}/activity/delete-#{(Time.current.to_f * 1000).to_i}-#{SecureRandom.hex(4)}",
        "type" => "Delete",
        "actor" => Urls.actor_url(sender),
        "to" => [JsonLd::PUBLIC],
        "object" => {"type" => "Tombstone", "id" => uri}
      }
      enqueue(payload, sender: sender, inboxes: inboxes)
      Logging.log(:out, "Delete", status: "comment_queued", comment: comment.id)
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
            # ms precision + random tail: two saves in the same second must
            # not share an id, or the peer's idempotency ledger drops the
            # second update as a replay
            "id" => "#{Urls.event_url(event)}/activity/#{verb}-#{(event.updated_at.to_f * 1000).to_i}-#{SecureRandom.hex(4)}",
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
        "id" => "#{uri}/activity/delete-#{(Time.current.to_f * 1000).to_i}-#{SecureRandom.hex(4)}",
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
      # Snapshot the signing identity NOW: by delivery time the sender row may
      # be gone (a deleted group announcing its own Delete) or its key rotated,
      # and the payload's actor must still verify against the key it names.
      key_id, key_pem =
        if sender.respond_to?(:federation_keypair!)
          [Urls.key_id(sender), sender.federation_keypair!.to_pem]
        else
          [Urls.instance_key_id, FedInstanceKey.current.private_key]
        end
      # One transaction for the whole fan-out (joining the caller's when there
      # is one): a failure mid-loop must not leave some inboxes owed the
      # activity and others not.
      rows = ActiveRecord::Base.transaction do
        inboxes.map { |inbox|
          FedDelivery.create!(payload: payload, sender_type: sender.class.name,
                              sender_id: sender.id, inbox_url: inbox,
                              signing_key_id: key_id, signing_key_pem: key_pem)
        }
      end
      # after_commit so the sweeper never races an uncommitted row
      ActiveRecord::Base.current_transaction.after_commit { Federation::SweeperJob.perform_later }
      rows
    end
  end
end
