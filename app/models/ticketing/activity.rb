# One thing that happened to an order (or another ticketing subject).
#
# Append-only: rows are written, never updated or deleted. A row is an
# observation, and observations do not change — anything that "changes" is a
# later row. That is the property the table is for, so it is enforced here
# rather than left to convention.
class Ticketing::Activity < ApplicationRecord
  belongs_to :subject, polymorphic: true
  belongs_to :actor, class_name: "User", optional: true, foreign_key: :actor_user_id

  # The vocabulary. Deliberately wider than the status machine: the things
  # that most need explaining after the fact — a retry, a callback we refused,
  # a dispute lost — are not status changes at all, which is why a
  # "transitions" table would have missed exactly the interesting cases.
  ACTIONS = %w[
    order_placed
    prepay_created
    checkout_session_created
    payment_confirmed
    payment_failed
    payment_retried
    callback_rejected
    order_expired
    order_cancelled
    inventory_released
    refund_requested
    refund_succeeded
    refund_failed
    dispute_opened
    dispute_won
    dispute_lost
    coupon_redeemed
    ticket_granted
    status_changed
  ].freeze

  # Who or what did it. `system` is the honest answer when a transition has no
  # identifiable trigger; `backfill` marks rows reconstructed from timestamps
  # after the fact, so they can never be mistaken for something observed.
  SOURCES = %w[api webhook sweeper reconciliation system backfill].freeze

  validates :action, inclusion: { in: ACTIONS }
  validates :source, inclusion: { in: SOURCES }

  scope :recorded, -> { where.not(source: "backfill") }
  scope :oldest_first, -> { order(:created_at, :id) }

  # The only way to write one. Never raises into the caller: an audit row that
  # fails must not take a payment down with it — a lost row is bad, a lost
  # confirmation is worse.
  def self.record!(subject, action, source:, from: nil, to: nil, actor: nil, reason: nil, **metadata)
    create!(
      subject: subject, action: action.to_s, source: source.to_s,
      from_status: from, to_status: to,
      actor_user_id: actor.respond_to?(:id) ? actor.id : actor,
      reason: reason, metadata: metadata.compact
    )
  rescue => e
    Rails.error.report(e, handled: true, context: {
      subject_type: subject.class.name, subject_id: subject.id, action: action
    })
    nil
  end

  # Which action a status change means. The same destination says different
  # things depending on where it came from: `refunded` is a refund when it
  # follows a payment and a lost chargeback when it follows a dispute, and
  # after the fact those are the two facts nobody could tell apart.
  def self.action_for_transition(from, to)
    case [ from, to ]
    in [ "disputed", "succeeded" ] then "dispute_won"
    in [ "disputed", "refunded" ] then "dispute_lost"
    else
      case to
      when "succeeded" then "payment_confirmed"
      when "timeout" then "order_expired"
      when "cancelled" then "order_cancelled"
      when "refunded", "partially_refunded" then "refund_succeeded"
      when "disputed" then "dispute_opened"
      else "status_changed"
      end
    end
  end

  def backfilled? = source == "backfill"

  private

  def readonly? = persisted?
end
