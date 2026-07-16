class GroupPolicy < ApplicationPolicy
  def index?   = true
  def show?    = true
  def create?  = !user.nil?
  def update?  = manages?(record)
  def destroy? = manages?(record)
  def manage?  = manages?(record)

  # Freezing (deactivating) a group is owner-only — group admins manage
  # content, but only an owner (or a platform admin) can take it offline.
  def freeze?  = user ? (user.platform_admin? || user.memberships.exists?(group: record, role: "owner")) : false

  # Who may view the member roster: members of the group, or a manager
  # (including a parent-group manager).
  def members? = group_member?(record) || manages?(record)

  private

  # A group is managed by its own admins/owners, by managers of its parent
  # group (per the Parent-Child Groups contract), and by platform admins
  # (who curate/remove popup cities).
  def manages?(group)
    return false unless group
    return true if user&.platform_admin?
    group_admin?(group) || (group.parent && group_admin?(group.parent))
  end
end
