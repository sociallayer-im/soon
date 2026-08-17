class CategoryPolicy < ApplicationPolicy
  def index? = true
  def show?  = record.visible_to?(user)

  # Creating, editing, archiving, deleting and managing the invited list are
  # all one permission: managing the group the board belongs to.
  def create?  = manages_group?
  def update?  = manages_group?
  def destroy? = manages_group?
  def manage_members? = manages_group?

  private

  def manages_group?
    group = record.is_a?(Category) ? record.group : record
    GroupPolicy.new(user, group).manage?
  end
end
