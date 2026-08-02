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

  # No uniqueness *validation* on uri — that would be check-then-insert and
  # defeat record!'s race-on-the-index semantics. The unique index is the law.
  validates :uri, presence: true
  validates :status, inclusion: {in: STATUSES}

  # Insert-first (not check-first) so two concurrent deliveries of the same
  # activity race on the unique index, not on a read. Returns
  #   :new       — first sighting, caller should enqueue processing
  #   :retry     — a previously failed activity, claimed for reprocessing
  #   :duplicate — already received/processed/ignored, caller no-ops
  def self.record!(uri:, activity_type: nil, fed_actor_id: nil)
    create!(uri: uri, activity_type: activity_type, fed_actor_id: fed_actor_id,
            status: "received")
    :new
  rescue ActiveRecord::RecordNotUnique
    # Atomic claim: of N concurrent redeliveries of a failed activity,
    # exactly one flips the row back and re-runs it.
    claimed = where(uri: uri, status: "failed").update_all(status: "received")
    claimed.positive? ? :retry : :duplicate
  end

  def self.mark!(uri, status)
    where(uri: uri).update_all(status: status)
  end
end
