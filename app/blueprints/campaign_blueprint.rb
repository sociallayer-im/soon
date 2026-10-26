class CampaignBlueprint < Blueprinter::Base
  identifier :id
  fields :owner_id, :group_id, :title, :kicker, :introduction, :featured_image_url, :status, :round,
    :resource_links, :created_at, :updated_at

  field :event_ids do |campaign, options|
    options[:editor] ? campaign.event_ids : campaign.published_event_ids
  end

  field :event_statuses, if: ->(_name, _campaign, options) { options[:editor] } do |campaign|
    campaign.event_statuses
  end
end
