class EventPolicy < ApplicationPolicy
  def index?  = true

  # Draft/archived events are visible only to the owner or a group manager.
  # Public events are visible to anyone; private events to group members.
  def show?
    return owner?(record) || group_admin?(record.group) if %w[draft archived].include?(record.status)
    return true if record.visibility == "public"
    owner?(record) || group_member?(record.group) # private
  end

  def create?  = group_member?(record.group)
  def update?  = owner?(record) || group_admin?(record.group)
  def destroy? = owner?(record) || group_admin?(record.group)
end
