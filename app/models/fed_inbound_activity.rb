# Idempotency ledger for the inbox: one row per activity id ever accepted.
# A second delivery of the same id is a 202 no-op (at-least-once senders
# re-deliver on retry and crash recovery — design/FEDERATION_TEST_PLAN.md §1).
class FedInboundActivity < ApplicationRecord
  STATUSES = %w[processed failed ignored].freeze

  # No uniqueness *validation* on uri — that would be check-then-insert and
  # defeat record!'s race-on-the-index semantics. The unique index is the law.
  validates :uri, presence: true
  validates :status, inclusion: {in: STATUSES}

  # Returns false if the uri was already recorded — the caller skips
  # processing. Insert-first (not check-first) so two concurrent deliveries
  # of the same activity race on the unique index, not on a read.
  def self.record!(uri:, activity_type: nil, fed_actor_id: nil, status: "processed")
    create!(uri: uri, activity_type: activity_type, fed_actor_id: fed_actor_id, status: status)
    true
  rescue ActiveRecord::RecordNotUnique
    false
  end
end
