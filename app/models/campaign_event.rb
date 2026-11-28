class CampaignEvent < ApplicationRecord
  belongs_to :campaign
  belongs_to :event
  after_destroy do
    Campaign.where(id: campaign_id).update_all(["positions = array_remove(positions, ?)", event_id])
  end
  validates :event_id, uniqueness: { scope: :campaign_id }
end
