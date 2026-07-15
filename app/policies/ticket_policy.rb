class TicketPolicy < ApplicationPolicy
  def manage? = owner?(record.event) || group_admin?(record.event.group)

  private

  def owner?(event) = event.owner_id == user&.id
end
