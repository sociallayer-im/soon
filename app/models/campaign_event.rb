class CampaignEvent < ApplicationRecord
  surf_visible_by(:event_id) { Event.select(:id) }
  surf_visible_by(:campaign_id) { Campaign.select(:id) }

  belongs_to :campaign
  belongs_to :event
  after_destroy do
    Campaign.where(id: campaign_id).update_all(["positions = array_remove(positions, ?)", event_id])
  end
  validates :event_id, uniqueness: { scope: :campaign_id }
end
