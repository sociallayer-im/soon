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
    was_seated = seated?
    transaction do
      update!(attrs.merge(status: to))
      sync_event_seat!(was_seated)
    end
  end

  # `events.participant_count` counts SEATED participants, so it moves when and
  # only when this row's seatedness does — which is here.
  #
  # It used to be maintained by whoever happened to trigger the change, and one
  # of those was TicketItem#release_resources!, which fires per ORDER. Someone
  # holding two orders for one event lost their seat from the count by
  # abandoning the second one, and an order that never held a seat (a
  # need_approval buyer, still pending) gave one back on cancel — taking it
  # from whoever else was counted. Tying the counter to the status that defines
  # it is what makes those unrepresentable.
  #
  # The create/re-join paths (participants#create, tickets#rsvp) still adjust
  # it themselves, because they assign_attributes rather than transition!.
  # That is safe for one specific reason: the only rows they may reuse are
  # `cancelled` and `declined`, neither of which holds a seat, so their
  # increment can never double-count. Anything else must go through here.
  #
  # Private: it takes the PREVIOUS seatedness as an argument, which only
  # transition! is in a position to know. Called from anywhere else it would
  # silently move the counter by an arbitrary amount.
  private def sync_event_seat!(was_seated)
    return if was_seated == seated?

    if seated?
      event.increment!(:participant_count)
    elsif event.participant_count.to_i > 0
      event.decrement!(:participant_count)
    end
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
