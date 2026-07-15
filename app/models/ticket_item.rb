class TicketItem < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :ticket
  belongs_to :event, optional: true
  belongs_to :participant, optional: true
  belongs_to :payment_method, optional: true
  belongs_to :group, optional: true
  belongs_to :coupon, optional: true

  validates :status, inclusion: { in: %w(pending unbounded succeeded cancelled timeout) }
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
    if participant&.payment_status == "pending"
      participant.update(payment_status: "cancelled", status: "cancelled")
    end
    update(status: "cancelled", participant_id: nil)
    coupon&.increment!(:order_usage_count)
  end

  def timeout
    if participant&.payment_status == "pending"
      participant.update(payment_status: "cancelled", status: "cancelled")
    end
    update(status: "timeout", participant_id: nil)
    coupon&.increment!(:order_usage_count)
  end

  def notify_group_owner
    return unless ticket_type == "group" && group.present? && status == "succeeded"

    group_owner = group.users.joins(:memberships).where(memberships: { role: "owner" }).first
    return unless group_owner&.email.present?

    # TODO: wire to a GroupMailer once soon/'s mail setup exists.
  end
end
