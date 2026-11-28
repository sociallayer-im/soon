class CampaignReviewLog < ApplicationRecord
  belongs_to :campaign
  belongs_to :reviewer, class_name: "User", optional: true
  validates :decision, inclusion: {in: %w[approved rejected resubmitted]}
end
