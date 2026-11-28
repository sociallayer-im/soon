class CampaignReviewLog < ApplicationRecord
  surf_visible_by(:campaign_id) { Campaign.select(:id) }

  belongs_to :campaign
  belongs_to :reviewer, class_name: "User", optional: true
  validates :decision, inclusion: {in: %w[approved rejected resubmitted]}
end
