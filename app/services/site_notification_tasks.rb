# A live projection: reading a task cannot complete it, and another manager's decision
# removes it for everyone. No stale persisted authorization or duplicate roles.
class SiteNotificationTasks
  def self.for(user)
    tasks = []
    managed = user.memberships.where(role: %w[owner manager]).select(:group_id)
    if user.platform_admin?
      Group.where(review_status: "pending").find_each do |group|
        tasks << task("group_review", group, "群组等待审核", group.nickname.presence || group.name, "group-detail", group.id)
      end
    end
    Event.where(status: "pending", group_id: managed).find_each do |event|
      tasks << task("event_review", event, "活动等待发布审核", event.title, "event-detail", event.id)
    end
    editable = Event.where(owner_id: user.id).or(Event.where(group_id: managed))
                    .or(Event.where(id: EventRole.linked_to(user).where(role: EventPolicy::EDITOR_ROLES).select(:event_id)))
    Participant.where(status: "pending", event_id: editable.where("events.status IS NULL OR events.status NOT IN (?)", %w[cancelled archived draft]).select(:id)).includes(:event, :user).find_each do |participant|
      tasks << task("participant_review", participant, "报名申请待审核", "#{participant.user.nickname.presence || participant.user.name.presence || 'Surf 成员'} 申请参加「#{participant.event.title}」", "event-detail", participant.event_id)
    end
    GroupInvite.where(group_id: managed, status: "requesting").where("expires_at IS NULL OR expires_at > ?", Time.current).includes(:group, :receiver).find_each do |invite|
      tasks << task("group_request", invite, "加入群组申请待审核", "#{invite.receiver&.nickname.presence || invite.receiver&.name.presence || 'Surf 成员'} 申请加入「#{invite.group.nickname.presence || invite.group.name}」", "group-detail", invite.group_id)
    end
    tasks.sort_by { |t| [t[:created_at], t[:id]] }
  end

  def self.task(kind, item, title, body, page, target_id)
    {id: "#{kind}:#{item.id}", kind: kind, resource_id: item.id, title: title, body: body,
     created_at: item.created_at.iso8601, target: {page: page, id: target_id},
     event_id: item.try(:event_id), group_id: item.try(:group_id)}
  end
end
