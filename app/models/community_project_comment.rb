class CommunityProjectComment < ApplicationRecord
  belongs_to :community_project
  belongs_to :user
  validates :content, presence: true, length: { maximum: 3000 }
end
