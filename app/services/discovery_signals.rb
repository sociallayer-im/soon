class DiscoverySignals
  def self.public_topics
    Topic.joins(:category, :group).where(flagged_at: nil, sync_to_community: true,
      categories: {visibility: "public", archived: false}, groups: {active: true, review_status: "approved", discussion_enabled: true})
      .where("topics.event_id IS NULL OR topics.event_id IN (?)", Event.publicly_discoverable.select(:id))
  end

  def self.refresh_group!(id)
    return unless id
    latest_event = Event.where(group_id: id, status: "published", visibility: %w[normal open_registration]).order(created_at: :desc, id: :desc).limit(1).pick(:created_at)
    latest_post = public_topics.where(group_id: id).order(created_at: :desc, id: :desc).limit(1).pick(:created_at)
    Group.where(id: id).update_all(discovery_active_at: [latest_event, latest_post].compact.max)
  end
end
