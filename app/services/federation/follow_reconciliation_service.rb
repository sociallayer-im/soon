module Federation
  # Follow reconciliation (INTEROP §10.3). The failure mode: our FedFollow
  # says "accepted", the peer's follower list says nothing — every layer
  # reports success while content silently never arrives (peer reinstall,
  # account purge, database rollback). No layer of the stack detects this on
  # its own, so it is detected here, on a schedule.
  #
  # Mechanism: re-send the ORIGINAL Follow (same activity id) for any
  # outbound edge without a recent confirmation. Peers treat a duplicate
  # Follow idempotently and answer Accept again (Mastodon re-sends Accept for
  # duplicates; so do we, InboxService#handle_follow) — that Accept is the
  # confirmation and stamps last_confirmed_at. A peer that dropped the edge
  # re-creates it from the probe, which *repairs* the drift rather than just
  # reporting it. MAX_PROBES probes with no Accept → the edge is presumed
  # dead and marked "lapsed" (visible, re-followable), never silently kept.
  #
  # The probe cycle also notices two things a lost Accept can't explain:
  # an actor that is gone (404/410 → purge all its edges) and an actor that
  # migrated while we weren't listening (movedTo on refetch → the same
  # attested re-point as an inbound Move).
  class FollowReconciliationService
    RECONCILE_AFTER = 7.days   # how long a confirmation is trusted
    PROBE_INTERVAL = 1.day     # minimum spacing between probes of one edge
    MAX_PROBES = 3
    BATCH = 25                 # per run; the fetch budget is shared with discovery

    def self.run(limit: BATCH)
      return unless Federation.enabled?
      lapse_exhausted
      stale_follows(limit).group_by(&:fed_actor).each do |actor, follows|
        reconcile_actor(actor, follows)
      end
    end

    # Outbound edges whose last proof of life is too old. pending is included:
    # a pending older than RECONCILE_AFTER usually means the Accept was lost,
    # and a same-id re-send is exactly the recovery for that.
    def self.stale_follows(limit)
      FedFollow.outbound.where(state: %w[pending accepted])
               .where("COALESCE(last_confirmed_at, fed_follows.created_at) < ?", RECONCILE_AFTER.ago)
               .where("probed_at IS NULL OR probed_at < ?", PROBE_INTERVAL.ago)
               .where(probe_count: ...MAX_PROBES)
               .includes(:fed_actor).limit(limit).to_a
    end

    def self.lapse_exhausted
      count = FedFollow.outbound.where(state: %w[pending accepted])
                       .where(probe_count: MAX_PROBES..)
                       .where("probed_at < ?", PROBE_INTERVAL.ago)
                       .update_all(state: "lapsed", updated_at: Time.current)
      Logging.log(:out, "Reconcile", status: "lapsed", count: count) if count.positive?
    end

    def self.reconcile_actor(actor, follows)
      # A recently-fetched actor is known alive and unmoved; only stale ones
      # cost a network round trip (and draw from the discovery budget).
      refreshed =
        if actor.stale?
          begin
            ActorFetchService.fetch!(actor.uri)
          rescue ActorFetchService::FetchError => e
            return purge_gone(actor) if e.message.match?(/HTTP (404|410) /)
            return # transient — retry next cycle without spending a probe
          rescue HttpClient::Error
            return
          end
        else
          actor
        end

      return repoint_moved(refreshed, follows) if refreshed.moved_to.present?
      follows.each { |f| probe(f) }
    end

    # 404/410 on the actor id: the identity no longer exists. Every edge in
    # both directions is dead weight (and inbound ones cause pointless
    # deliveries), so they all go.
    def self.purge_gone(actor)
      count = actor.fed_follows.count
      actor.fed_follows.destroy_all
      Logging.log(:out, "Reconcile", status: "actor_gone_purged",
                  domain: actor.domain, follows: count)
      nil
    end

    # The peer migrated while we weren't listening — a Move we never received
    # (delivered during downtime, or Mobilizon-style peers that don't send
    # one). Same mutual-attestation re-point as InboxService#handle_move.
    def self.repoint_moved(actor, follows)
      target_uri = actor.moved_to
      return if Urls.local?(target_uri)
      begin
        target = ActorFetchService.fetch!(target_uri)
      rescue ActorFetchService::FetchError, HttpClient::Error
        return
      end
      unless target.also_known_as.include?(actor.uri)
        Logging.log(:out, "Reconcile", status: "move_attestation_missing", domain: actor.domain)
        return
      end
      follows.each do |f|
        OutboxService.follow(f.local, target)
        f.destroy!
      end
      Logging.log(:out, "Reconcile", status: "repointed_moved",
                  target: target_uri, follows: follows.size)
    end

    def self.probe(follow)
      payload = {
        "@context" => JsonLd::AS,
        "id" => follow.uri, # SAME id: peers dedupe duplicates by re-Accepting
        "type" => "Follow",
        "actor" => Urls.actor_url(follow.local),
        "object" => follow.fed_actor.uri,
        "to" => [follow.fed_actor.uri]
      }
      ActiveRecord::Base.transaction do
        follow.update!(probed_at: Time.current, probe_count: follow.probe_count + 1)
        OutboxService.enqueue(payload, sender: follow.local,
                              inboxes: [follow.fed_actor.delivery_inbox_url])
      end
      Logging.log(:out, "Reconcile", status: "probed", uri: follow.uri,
                  attempt: follow.probe_count)
    end
  end
end
