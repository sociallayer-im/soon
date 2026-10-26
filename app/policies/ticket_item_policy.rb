class TicketItemPolicy < ApplicationPolicy
  # Refunds: the event owner, a co-host, and a manager or owner of the
  # event's group. Group-ticket orders with no event still allow that
  # group's owner.
  def refund?
    return false unless user

    event = record.event
    if event
      return true if owner?(event)
      return true if event.event_roles.exists?(item_type: "User", item_id: user.id, role: "co_host")
      if event.group && event.group.memberships.exists?(user_id: user.id, role: %w[manager owner])
        return true
      end
    end
    record.ticket_type == "group" && record.group.present? &&
      record.group.memberships.exists?(user_id: user.id, role: "owner")
  end
end
