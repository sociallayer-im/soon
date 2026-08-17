# Which teams can see a `visibility: "team"` board.
class CategoryTeam < ApplicationRecord
  belongs_to :category
  belongs_to :team

  validates :team_id, uniqueness: { scope: :category_id }
  validate :team_must_belong_to_the_same_group

  private

  def team_must_belong_to_the_same_group
    return if team.nil? || category.nil?
    return if team.group_id == category.group_id

    errors.add(:team, "belongs to another group")
  end
end
