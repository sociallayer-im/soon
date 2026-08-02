# Idempotency ledger for the inbox: one row per activity id ever accepted.
# A second delivery of the same id is a 202 no-op (at-least-once senders
# re-deliver on retry and crash recovery — design/FEDERATION_TEST_PLAN.md §1).
#
# Lifecycle: rows are inserted as "received" when the activity clears the
# inbox gauntlet, and moved to processed/ignored/failed by InboundJob. A
# redelivery of a *failed* activity is the remote's retry doing exactly what
# at-least-once delivery is for, so it re-runs instead of being dropped as a
# duplicate — the earlier design stamped "processed" before the job ever ran,
# which turned every processing failure into a permanently lost activity.
class FedInboundActivity < ApplicationRecord
  STATUSES = %w[received processed failed ignored].freeze
  # A "received" row this old with no terminal state means the process died
  # between the ledger write and the job enqueue — the enqueued job would
  # have settled it long ago. Let the remote's redelivery claim it.
  STALE_RECEIVED_AFTER = 15.minutes

  # No uniqueness *validation* on uri — that would be check-then-insert and
  # defeat record!'s race-on-the-index semantics. The unique index is the law.
  validates :uri, presence: true
  validates :status, inclusion: {in: STATUSES}

  # Insert-first (not check-first) so two concurrent deliveries of the same
  # activity race on the unique index, not on a read. Returns
  #   :new       — first sighting, caller should enqueue processing
  #   :retry     — a failed (or crash-stranded) activity, claimed to re-run
  #   :duplicate — already received/processed/ignored, caller no-ops
  #   :conflict  — same uri but a DIFFERENT actor/type/body: someone is
  #                replaying or pre-claiming another party's activity id
  def self.record!(uri:, activity_type: nil, fed_actor_id: nil, body_digest: nil)
    create!(uri: uri, activity_type: activity_type, fed_actor_id: fed_actor_id,
            body_digest: body_digest, status: "received")
    :new
  rescue ActiveRecord::RecordNotUnique
    existing = find_by(uri: uri)
    return :retry if existing.nil? # deleted between insert and read; rare — treat as claimable miss

    # The idempotency claim binds to who sent what, not just the id the
    # remote chose. A different ACTOR or TYPE under the same id is a forgery
    # or pre-claim and must not share the claim (P1-4). A body-digest drift
    # alone (same actor, same type) is tolerated as re-serialization — a peer
    # rebuilding its payload on retry must not be rejected as an attacker —
    # but it is logged for forensics.
    if mismatch?(existing, fed_actor_id, activity_type)
      return :conflict
    end
    if existing.body_digest.present? && body_digest.present? && existing.body_digest != body_digest
      Rails.logger.warn("[fed] inbound #{uri}: body digest drift on redelivery")
    end

    # Atomic claim: of N concurrent redeliveries of a failed activity,
    # exactly one flips the row back and re-runs it. Stranded "received"
    # rows (crash before enqueue) become claimable after a grace period.
    claimed = where(uri: uri)
              .where("status = 'failed' OR (status = 'received' AND created_at < ?)",
                     STALE_RECEIVED_AFTER.ago)
              .update_all(status: "received", created_at: Time.current)
    claimed.positive? ? :retry : :duplicate
  end

  def self.mismatch?(existing, fed_actor_id, activity_type)
    (existing.fed_actor_id.present? && fed_actor_id.present? && existing.fed_actor_id != fed_actor_id) ||
      (existing.activity_type.present? && activity_type.present? && existing.activity_type != activity_type)
  end

  def self.digest(body)
    Digest::SHA256.hexdigest(body.to_s)
  end

  def self.mark!(uri, status)
    where(uri: uri).update_all(status: status)
  end
end
