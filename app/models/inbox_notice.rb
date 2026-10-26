class InboxNotice
  def self.registration!(participant, initiator:)
    registration_requested(participant, initiator: initiator)
    registration_confirmed(participant, initiator: initiator)
  end

  def self.registration_requested(participant, initiator:)
    return unless participant.status == "pending"
    return if noticed_since_registration?(participant, "registration/requested")

    receivers(participant).each do |user_id|
      write(receiver_id: user_id, initiator: initiator, action: "registration/requested", item: participant,
        payload: { "event_id" => participant.event_id, "participant_id" => participant.id, "title" => participant.event.title })
    end
  end

  def self.registration_confirmed(participant, initiator:)
    return unless participant.confirmed_public?
    return if noticed_since_registration?(participant, "registration/confirmed")

    write(receiver_id: participant.user_id, initiator: initiator, action: "registration/confirmed", item: participant,
      payload: { "event_id" => participant.event_id, "participant_id" => participant.id, "title" => participant.event.title })
  end

  def self.for_comment(comment)
    return unless comment.item_type == "Event"
    return unless %w[comment recommendation].include?(comment.comment_type)

    event = Event.find_by(id: comment.item_id)
    return unless event
    return if event.owner_id == comment.user_id

    action = comment.comment_type == "recommendation" ? "recommendation/created" : "comment/created"
    write(receiver_id: event.owner_id, initiator: comment.user, action: action, item: comment,
      payload: { "event_id" => event.id, "title" => event.title })
  end

  def self.event_cancelled(event, initiator:)
    event.participants.confirmed_public.find_each do |participant|
      write(receiver_id: participant.user_id, initiator: initiator, action: "event/cancelled", item: event,
        payload: { "event_id" => event.id, "title" => event.title })
    end
  end

  def self.campaign_published(campaign, initiator:)
    Event.where(id: campaign.published_event_ids).find_each do |event|
      next if event.owner_id == campaign.owner_id

      write(receiver_id: event.owner_id, initiator: initiator, action: "campaign/published", item: campaign,
        payload: { "campaign_id" => campaign.id, "event_id" => event.id, "title" => campaign.title })
    end
  end

  def self.receivers(participant)
    event = participant.event
    ids = event.group.memberships.where(role: %w[manager owner]).pluck(:user_id)
    ids << event.owner_id
    ids.compact.uniq - [ participant.user_id ]
  end

  def self.noticed_since_registration?(participant, action)
    return false if participant.registered_at.blank?

    Activity.where(item: participant, action: action).where("created_at >= ?", participant.registered_at).exists?
  end

  def self.write(receiver_id:, initiator:, action:, item:, payload: {})
    return if receiver_id.blank? || initiator.nil?

    Activity.create!(receiver_id: receiver_id, initiator: initiator, action: action, item: item, payload: payload)
  end
end
