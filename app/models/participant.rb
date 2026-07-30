# One person's relationship to one event. Unique per (user, event) — the row
# is reused across withdraw/re-join rather than duplicated.
#
# ## Lifecycle
#
# `status` is the single lifecycle column. It carries three concerns that used
# to be read inconsistently across the codebase, so they are spelled out here:
#
#   attending  — holds a seat. The ONLY status counted by participant_count,
#                capacity checks, is_attending, and attendee mail.
#   pending    — awaiting the organizer's approval (require_approval, an
#                application form, or a need_approval ticket). Holds no seat.
#   declined   — the organizer rejected them. Terminal unless they re-apply.
#   maybe      — soft RSVP intent. Holds no seat.
#   cancelled  — SOFT DELETE: they withdrew. Holds no seat, hidden from every
#                attendee list, but the row survives for history and so a
#                later refund can still reach it. Re-joining reuses the row.
#
#   (new) ──rsvp/join──► attending ──withdraw──► cancelled ──re-join──► attending
#     │                    │  ▲                                │
#     │                    │  └────────approve─────────────┐   │
#     └──needs approval──► pending ──reject──► declined     │   │
#                            │                    │        │   │
#                            └──withdraw──► cancelled ◄────┘   │
#                                                              │
#                          maybe ◄──update──► attending ───────┘
#
# `payment_status` is NOT independent: it is a derived summary of the person's
# ticket_items for this event (see #refresh_payment_status!). Four different
# call sites used to write it directly, which let it disagree with the orders
# it describes — e.g. cancelling one pending order marked the whole
# participant unpaid even when another order was already paid.
class Participant < ApplicationRecord
  belongs_to :user
  belongs_to :event
  belongs_to :voucher, optional: true
  belongs_to :badge, optional: true

  STATUSES = %w[attending pending declined maybe cancelled].freeze

  # Statuses that occupy a seat: participant_count, max_participant, venue
  # capacity, is_attending and attendee mail all key off exactly this.
  SEATED = %w[attending].freeze

  # Allowed lifecycle moves. Enforced by #transition!; direct status writes
  # bypass it, so prefer transition! for anything a user action triggers.
  TRANSITIONS = {
    "attending" => %w[maybe declined cancelled],
    "pending"   => %w[attending declined cancelled],
    "maybe"     => %w[attending declined cancelled],
    "declined"  => %w[attending pending cancelled],
    # Re-joining a cancelled row is how withdraw/re-join works.
    "cancelled" => %w[attending pending maybe]
  }.freeze

  class InvalidTransition < StandardError; end

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :user_id, uniqueness: { scope: :event_id, message: "can only participate once per event" }

  scope :active, -> { where.not(status: "cancelled") }
  scope :seated, -> { where(status: SEATED) }

  def cancelled? = status == "cancelled"
  def seated?    = SEATED.include?(status)

  def transition!(to, **attrs)
    to = to.to_s
    unless TRANSITIONS.fetch(status, []).include?(to)
      raise InvalidTransition, "participant #{id}: #{status} → #{to}"
    end
    attrs[:cancelled_at] = to == "cancelled" ? Time.current : nil
    update!(attrs.merge(status: to))
  end

  # Recomputes payment_status from the orders it summarises, so it can never
  # contradict them:
  #   nil        — no orders at all (a free event with no ticket types)
  #   succeeded  — at least one paid/settled order
  #   pending    — an order is awaiting payment and none has settled
  #   cancelled  — every order is cancelled/expired/refunded
  def refresh_payment_status!
    statuses = ticket_items.pluck(:status)
    self.payment_status =
      if statuses.empty? then nil
      elsif statuses.intersect?(%w[succeeded partially_refunded disputed]) then "succeeded"
      elsif statuses.include?("pending") then "pending"
      else "cancelled"
      end
    save! if changed?
    payment_status
  end

  def ticket_items = TicketItem.where(participant_id: id)
end
