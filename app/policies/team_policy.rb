class TeamPolicy < ApplicationPolicy
  # The roster is what a team annotates, so seeing teams follows seeing the
  # roster: members and managers.
  def index? = GroupPolicy.new(user, group).members?
  def show?  = index?

  # Teams confer no permission of their own, so managing them is just managing
  # the group — no separate role, and (per GroupPolicy's 2026-07-29 narrowing)
  # not a parent group's managers.
  def create?         = GroupPolicy.new(user, group).manage?
  def update?         = create?
  def destroy?        = create?
  def manage_members? = create?

  private

  def group
    record.is_a?(Team) ? record.group : record
  end
end
