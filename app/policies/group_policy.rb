class GroupPolicy < ApplicationPolicy
  def index?   = true
  def show?    = true
  def create?  = !user.nil?
  def update?  = manages?(record)
  def destroy? = manages?(record)
  def manage?  = manages?(record)

  # Freezing (deactivating) a group is owner-only — admins manage content,
  # but only an owner can take the whole group offline.
  def freeze?  = user ? user.memberships.exists?(group: record, role: "owner") : false

  # Who may view the member roster: members of the group, or a manager
  # (including a parent-group manager).
  def members? = group_member?(record) || manages?(record)

  private

  # A group is managed by its own admins/owners, and — per the Parent-Child
  # Groups contract — by managers of its parent group.
  def manages?(group)
    return false unless group
    group_admin?(group) || (group.parent && group_admin?(group.parent))
  end
end
