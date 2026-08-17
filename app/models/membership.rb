class Membership < ApplicationRecord
  belongs_to :user
  # counter_cache keeps groups.memberships_count correct on every create/destroy
  # (including the owner seeded at group creation), so nothing has to remember to
  # increment/decrement it by hand.
  belongs_to :group, counter_cache: :memberships_count

  validates :user_id, uniqueness: { scope: :group_id, message: "can only join a group once" }
  validates :role, inclusion: { in: %w[member manager owner] }

  # A team groups a group's members, so leaving the group leaves its teams
  # too. Without this the tables keep rows for people who are no longer in the
  # community but still carry its identity — and, through a team-restricted
  # discussion board, still its access.
  after_destroy :leave_group_teams

  private

  def leave_group_teams
    TeamMembership.where(user_id: user_id, team_id: Team.where(group_id: group_id).select(:id))
                  .find_each(&:destroy)
  end
end
