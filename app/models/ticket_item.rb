class TicketItem < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :ticket
  belongs_to :event, optional: true
  belongs_to :participant, optional: true
  belongs_to :payment_method, optional: true
  belongs_to :group, optional: true
  belongs_to :coupon, optional: true

  has_many :refunds, dependent: :destroy

  class InvalidTransition < StandardError; end

  # The order state machine (design/PAYMENTS_PLAN.md §3.6). Wire names are
  # kept from the legacy vocabulary — pending == awaiting_payment,
  # succeeded == paid, timeout == expired — because the deployed frontend
  # matches on these strings. "unbounded" (sails' unclaimed email-grant
  # state) was removed 2026-07-30; that flow lives in GroupInvite now.
  #
  #   pending ──(payment verified)──► succeeded ──► refunded | partially_refunded | disputed
  #      └──(user cancel | sweeper)──► cancelled | timeout
  #   disputed ──(dispute won)──► succeeded, (lost/conceded)──► refunded
  TRANSITIONS = {
    "pending"             => %w[succeeded cancelled timeout],
    "succeeded"           => %w[refunded partially_refunded disputed],
    "partially_refunded"  => %w[refunded partially_refunded disputed],
    "disputed"            => %w[succeeded refunded],
    "cancelled"           => [],
    "timeout"             => [],
    "refunded"            => []
  }.freeze

  validates :status, inclusion: { in: TRANSITIONS.keys }

  # Every status change funnels through here so the allowed-transition table
  # is actually enforced — nothing else may write `status`.
  def transition!(to, **attrs)
    to = to.to_s
    unless TRANSITIONS.fetch(status, []).include?(to)
      raise InvalidTransition, "ticket_item #{id}: #{status} → #{to}"
    end
    update!(attrs.merge(status: to))
  end
  validates :ticket_type, inclusion: { in: %w(event group) }

  enum :auth_type, { free: "free", payment: "payment", badge: "badge", invite: "invite" }

  # Only meaningful for group tickets: checks whether this ticket's date/track
  # restrictions grant access to a specific event within the group.
  def check_permission(event)
    return false unless ticket_type == "group"

    tz = event.group.timezone.presence || "UTC"
    event_period = (event.start_time.in_time_zone(tz).to_date..event.end_time.in_time_zone(tz).to_date)

    if ticket.start_date.present?
      return false unless (ticket.start_date..ticket.end_date).overlaps?(event_period)
    elsif ticket.days_allowed.present?
      return false unless ticket.days_allowed.any? { |day| event_period.include?(day) }
    end

    # todo : use track_id
    if ticket.tracks_allowed.present?
      return false unless ticket.tracks_allowed.intersect?(event.tags)
    end

    true
  end

  def cancel
    close!("cancelled")
  end

  def timeout
    close!("timeout")
  end

  # Confirms payment on every rail (crypto verify_payment, webhook
  # set_payment_status, and stripe_callback all funnel through here) so the
  # succeed-side effects can't drift between paths. Verification of the payment
  # itself happens in the controller before this is called.
  def confirm_payment!(txhash: nil, sender_address: nil)
    attrs = { paid_at: Time.current }
    attrs[:txhash] = txhash if txhash.present?
    attrs[:sender_address] = sender_address if sender_address.present?

    newly_paid = participant && participant.payment_status != "succeeded"
    transaction do
      if status == "succeeded"
        # Already-paid items (free path creates them succeeded directly, and
        # this also runs for the confirm side effects) just take the attrs.
        update!(attrs)
      else
        transition!(:succeeded, **attrs)
      end
      if ticket_type == "group" && group && !group.memberships.exists?(user_id: user_id)
        group.add_member(user_id, "member")
      end
      participant.update!(payment_status: "succeeded") if newly_paid
    end
    # Only on the first confirmation — a repeat webhook/callback for an
    # already-succeeded purchase shouldn't re-email the buyer.
    EventMailer.ticket_purchased(participant_id: participant.id).deliver_later if newly_paid
    notify_group_owner
  end

  def notify_group_owner
    return unless ticket_type == "group" && group.present? && status == "succeeded"

    group_owner = group.users.joins(:memberships).where(memberships: { role: "owner" }).first
    return unless group_owner&.email.present?

    GroupMailer.ticket_purchased(ticket_item_id: id, recipient: group_owner.email).deliver_later
  end

  private

  # Shared teardown for cancel/timeout: releases the reserved ticket unit,
  # refunds the coupon usage consumed at RSVP, and undoes the participant_count
  # bump so a capacity-limited event doesn't drift toward "full" on abandoned
  # checkouts.
  def close!(new_status)
    transaction do
      if participant&.payment_status == "pending"
        participant.update!(payment_status: "cancelled", status: "cancelled")
      end
      transition!(new_status, participant_id: nil)
      release_resources!
    end
  end

  # Inventory is handed back exactly once per order, guarded by released_at —
  # never inferred from status. A second close/expire/refund path arriving
  # later becomes a no-op instead of double-crediting quantity or the coupon.
  # Public: the sweeper and the refund finalizer call it directly.
  public def release_resources!
    return if released_at

    transaction do
      update!(released_at: Time.current)
      event&.decrement!(:participant_count) if event && event.participant_count.to_i > 0
      coupon&.decrement!(:order_usage_count) if coupon && coupon.order_usage_count.to_i > 0
    end
    ticket.release!
  end
end
