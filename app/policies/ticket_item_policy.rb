class TicketItemPolicy < ApplicationPolicy
  # Refunds (design/PAYMENTS_PLAN.md decision #6): the event owner and
  # co-hosts (EventRole "manager"); for group tickets additionally the group
  # owner. Deliberately narrower than EventPolicy#update? — group managers
  # do NOT get refund rights on regular events.
  def refund?
    return false unless user

    event = record.event
    if event
      return true if owner?(event)
      return true if event.event_roles.exists?(item_type: "User", item_id: user.id, role: "manager")
    end
    record.ticket_type == "group" && record.group.present? &&
      record.group.memberships.exists?(user_id: user.id, role: "owner")
  end
end
