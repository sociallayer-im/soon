class CommunityProjectMember < ApplicationRecord
  belongs_to :community_project
  belongs_to :user
  validates :role, length: { maximum: 80 }
end
