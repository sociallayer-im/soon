# One person's place in one team.
#
# No role column: the team IS the role. TrackRole has member/organizer/admin,
# which is not copied here — a role inside a team would be a second answer to
# "who may change this team", a question GroupPolicy#manage? already answers.
class TeamMembership < ApplicationRecord
  belongs_to :team
  belongs_to :user

  validates :user_id, uniqueness: { scope: :team_id, message: "is already in this team" }
  # A team groups a group's members, so someone outside the group cannot be in
  # one of its teams. Membership#destroy clears these; see Membership.
  validate :user_must_belong_to_the_group

  after_commit :refresh_team_count!, on: %i[create destroy]

  private

  def user_must_belong_to_the_group
    return if team.nil? || user_id.blank?
    return if Membership.exists?(group_id: team.group_id, user_id: user_id)

    errors.add(:user, "is not a member of this group")
  end

  # Looked up rather than taken from the association: destroying a team
  # destroys its memberships, and each of those would otherwise try to write a
  # count back onto the record that is already gone ("cannot update a
  # destroyed record"). A fresh find returns nil in exactly that case.
  def refresh_team_count!
    Team.find_by(id: team_id)&.refresh_members_count!
  end
end
