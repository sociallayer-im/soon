module Federation
  # Cross-instance participation, semantics mirrored from Mobilizon
  # (types/events.ex:146-248, actions/accept.ex, actions/reject.ex,
  # actions/leave.ex — see design/FEDERATION_PLAN.md §2.7):
  #   free       → participant seated immediately, Accept sent back
  #   restricted → participant pending, Accept/Reject follows the local
  #                approval UI
  #   external   → Reject (ticketed events are bought at the source)
  #   over capacity → Reject, nothing seated
  # Only the event's own instance may accept — we are that instance here.
  class ParticipationService
    def self.join(fed_actor, activity)
      event = resolve_event(activity["object"])
      return :ignored if event.nil?
      return reject(event, fed_actor, activity, "event is not open") unless joinable?(event)

      mode = EventSerializer.new(event).join_mode
      return reject(event, fed_actor, activity, "external registration required") if mode == "external"

      existing = Participant.find_by(event: event, fed_actor_id: fed_actor.id)
      return :ignored if existing && !existing.cancelled?

      seat = mode == "free"
      # cheap unlocked pre-check; the authoritative one is under the row lock
      return reject(event, fed_actor, activity, "event is full") if seat && full?(event)

      status = seat ? "attending" : "pending"
      participant = nil
      capacity_hit = false
      ActiveRecord::Base.transaction do
        # Serialize capacity: concurrent Joins each lock the event row, so the
        # count they check is the count their increment builds on — without
        # this, N Joins in flight all pass full? and the event oversells.
        event.lock!
        if seat && full?(event)
          capacity_hit = true
          raise ActiveRecord::Rollback
        end
        participant = existing || Participant.new(event: event, fed_actor_id: fed_actor.id)
        if existing
          participant.transition!(status, fed_join_uri: activity["id"], registered_at: Time.current,
                                          message: activity["participationMessage"])
        else
          participant.assign_attributes(status: status, fed_join_uri: activity["id"],
                                        registered_at: Time.current,
                                        message: activity["participationMessage"])
          participant.save!
        end
        event.increment!(:participant_count) if status == "attending"
        OutboxService.accept_join(event, fed_actor, activity, participant) if seat
      end
      return reject(event, fed_actor, activity, "event is full") if capacity_hit
      Logging.log(:in, "Join", domain: fed_actor.domain, status: status, event: event.id)
      seat ? :accepted : :pending
    end

    def self.leave(fed_actor, activity)
      event = resolve_event(activity["object"])
      return :ignored if event.nil?
      participant = Participant.find_by(event: event, fed_actor_id: fed_actor.id)
      return :ignored if participant.nil? || participant.cancelled?

      was_seated = participant.seated?
      participant.transition!("cancelled")
      event.decrement!(:participant_count) if was_seated && event.participant_count.to_i > 0
      Logging.log(:in, "Leave", domain: fed_actor.domain, status: "cancelled", event: event.id)
      :processed
    end

    # Called from the existing approve/reject endpoints so managers use one UI
    # for local and remote pending participants.
    def self.approve(participant)
      return unless participant.remote? && Federation.enabled?
      OutboxService.accept_join(participant.event, participant.fed_actor,
                                stored_join(participant), participant)
    end

    def self.decline(participant)
      return unless participant.remote? && Federation.enabled?
      OutboxService.reject_join(participant.event, participant.fed_actor, stored_join(participant))
    end

    def self.stored_join(participant)
      {
        "@context" => JsonLd::AS, "type" => "Join",
        "id" => participant.fed_join_uri,
        "actor" => participant.fed_actor.uri,
        "object" => Urls.event_url(participant.event)
      }
    end

    def self.joinable?(event)
      event.visibility == "public" && %w[published].include?(event.status) &&
        (event.end_time.nil? || event.end_time > Time.current)
    end

    def self.full?(event)
      cap = event.max_participant.presence || event.venue&.capacity
      cap.present? && event.participant_count.to_i >= cap
    end

    def self.reject(event, fed_actor, activity, reason)
      OutboxService.reject_join(event, fed_actor, activity, reason: reason)
      Logging.log(:in, "Join", domain: fed_actor.domain, status: "rejected", reason: reason)
      :rejected
    end

    def self.resolve_event(uri)
      return nil unless uri.is_a?(String) && Urls.local?(uri)
      id = URI.parse(uri).path[%r{\A/events/(.+)\z}, 1]
      id && Event.find_by(id: id)
    rescue URI::Error
      nil
    end
  end
end
