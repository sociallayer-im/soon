class CampaignEvent < ApplicationRecord
  belongs_to :campaign
  belongs_to :event
  validates :event_id, uniqueness: { scope: :campaign_id }
end
