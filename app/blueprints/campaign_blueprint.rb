class CampaignBlueprint < Blueprinter::Base
  identifier :id
  fields :group_id, :owner_id, :title, :kicker, :introduction, :media,
    :resource_links, :status, :created_at, :updated_at
  field :cover_url do |campaign|
    campaign.cover_url.presence || campaign.media.first&.fetch("url", nil)
  end
  field :can_edit do |campaign, options|
    CampaignPolicy.new(options[:current_user], campaign).update?
  end
  field :event_ids do |campaign, options|
    campaign.events.merge(Event.visible_to(options[:current_user])).pluck(:id)
  end
  field :cities do |campaign, options|
    ids = campaign.events.merge(Event.visible_to(options[:current_user])).select(:group_id)
    Group.where(id: ids).where.not(city: [nil, ""]).distinct.order(:city).pluck(:city)
  end
end
