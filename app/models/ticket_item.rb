class TicketItem < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :ticket
  belongs_to :event, optional: true
  belongs_to :participant, optional: true
  belongs_to :payment_method, optional: true
  belongs_to :group, optional: true
  belongs_to :coupon, optional: true

  has_many :refunds, dependent: :destroy

  # "unbounded" (sails' unclaimed email-grant state) was removed 2026-07-30 —
  # the flow lives in GroupInvite now and the legacy rows were deleted.
  validates :status, inclusion: { in: %w(pending succeeded cancelled timeout) }
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
    attrs = { status: "succeeded" }
    attrs[:txhash] = txhash if txhash.present?
    attrs[:sender_address] = sender_address if sender_address.present?

    newly_paid = participant && participant.payment_status != "succeeded"
    transaction do
      update!(attrs)
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
      event&.decrement!(:participant_count) if event && event.participant_count.to_i > 0
      update!(status: new_status, participant_id: nil)
      coupon&.decrement!(:order_usage_count) if coupon && coupon.order_usage_count.to_i > 0
    end
    ticket.release!
  end
end
