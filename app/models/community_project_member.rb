class CommunityProjectMember < ApplicationRecord
  surf_visible_by(:community_project_id) { CommunityProject.select(:id) }

  belongs_to :community_project
  belongs_to :user
  validates :role, length: { maximum: 80 }
end
