# Station-only messages. Tasks are computed from current permissions/state, never from has_read.
class SiteNotifications
  ROLES = {"co_host"=>"共创者", "speaker"=>"演讲者", "judge"=>"评委", "custom_host"=>"主办方", "group_host"=>"主办方"}.freeze

  def self.emit(receiver:, item:, action:, title:, body:, actor: nil, key: nil, allow_self: false, payload: {})
    return unless receiver && (allow_self || receiver.id != actor&.id)
    key ||= "#{action}:#{item.class.name}:#{item.id}:#{item.updated_at&.iso8601(6)}"
    # Saves of this event hold its database row lock. Coalesce only unread
    # edits; a change after reading must create a fresh notification.
    if action == "event_updated"
      recent = Activity.for_receiver(receiver).unread.where(item: item, action: "surf/event_updated").where("created_at >= ?", 5.minutes.ago).order(created_at: :desc).first
      if recent
        recent.with_lock do
          if !recent.has_read
            recent.update!(payload: {title: title, body: body}, created_at: Time.current)
            return recent
          end
        end
      end
    end
    Activity.create_or_find_by!(receiver_id: receiver.id, notification_key: key) do |notice|
      notice.initiator = actor || receiver
      notice.item = item
      notice.action = "surf/#{action}"
      notice.payload = {title: title, body: body}.merge(payload)
    end
  end

  def self.record(record, changes, actor: nil)
    applicants = if record.is_a?(Campaign) || record.is_a?(Group) || record.is_a?(Event)
      User.where(id: ReviewNotifications.receipts(record).where("payload -> 'review' ->> 'status' = ?", "pending").select(:receiver_id)).to_a
    else
      []
    end
    ReviewNotifications.changed(record, changes, actor: actor)
    status = changes["status"]
    case record
    when Withdrawal
      return unless changes.key?("id") && record.status == "pending"
      User.where(active: true).where("admin = TRUE OR ? = ANY(permissions)", "admin").find_each do |receiver|
        emit(receiver: receiver, item: record, action: "withdrawal_requested", title: "收到新的提现申请",
          body: "「#{record.group.nickname.presence || record.group.name}」申请提现 ¥#{format('%.2f', record.amount / 100.0)}，请核对后安排线下结算。",
          actor: actor, key: "withdrawal_requested:#{record.id}:#{receiver.id}")
      end
    when RefundRequest
      transition = changes["status"]
      if changes.key?("id") || transition&.last == "rejected"
        event = record.ticket_item.event
        return unless event
        rejected = record.status == "rejected"
        ([record.user] + organizers(event).to_a).uniq(&:id).each do |receiver|
          emit(receiver: receiver, item: record, action: "refund_application", title: rejected ? "退出与退款申请未通过" : "收到退出与退款申请",
               body: "「#{event.title}」#{rejected ? '退款申请未通过：'+record.review_reason.to_s : '有退出与退款申请，请在订单中查看进度或处理。'}", actor: actor,
               key: "refund_request:#{record.id}:#{record.status}:#{receiver.id}", payload: {review_receipt_id: rejected ? ReviewNotifications.receipt_id(record, receiver) : nil})
        end
      end
    when Participant
      if record.status == "attending" && record.payment_status != "pending" && (changes.key?("id") || status&.last == "attending" || changes.dig("payment_status", 1) == "succeeded")
        organizers(record.event).find_each do |receiver|
          emit(receiver: receiver, item: record.event, action: "registration_received", title: "活动有新的报名", body: "#{record.user.nickname.presence || record.user.name.presence || 'Surf 成员'} 已报名「#{record.event.title}」。", actor: record.user,
               key: "registration_confirmed:#{record.id}:#{(record.registered_at || record.created_at).iso8601(6)}:#{receiver.id}")
        end
      end
      if status && status.last == "pending" && status.first != "pending"
        event = record.event
        managers = User.where(id: event.group.memberships.active.where(role: %w[owner manager]).select(:user_id)).or(User.where(id: event.owner_id))
        role_ids = event.event_roles.where(role: EventPolicy::EDITOR_ROLES, item_type: "User").pluck(:item_id)
        role_emails = event.event_roles.where(role: EventPolicy::EDITOR_ROLES).where.not(email: [nil, ""]).pluck(:email)
        managers = managers.or(User.where(id: role_ids)).or(User.where(email: role_emails))
        managers.distinct.find_each do |manager|
          emit(receiver: manager, item: event, action: "registration_request", title: "收到新的报名申请", body: "「#{event.title}」有报名申请待审核。", actor: record.user, key: "registration:#{record.id}:#{record.updated_at.iso8601(6)}:#{manager.id}")
        end
      end
      return unless status && status.first == "pending" && %w[attending awaiting_payment declined].include?(status.last)
      emit(receiver: record.user, item: record.event, action: "registration_result",
           title: status.last == "declined" ? "报名申请未通过" : "报名审核已通过",
           body: "「#{record.event.title}」#{status.last == 'declined' ? '未通过报名审核：'+record.review_reason.to_s : status.last == 'awaiting_payment' ? '审核通过，请在支付期限内完成付款。' : '审核通过，报名成功。'}", actor: actor,
           key: "participant:#{record.id}:#{record.updated_at.iso8601(6)}:#{status.last}", payload: {review_receipt_id: ReviewNotifications.receipt_id(record, record.user)})
    when Event
      return unless status || (changes.keys & %w[start_time end_time timezone venue_id place_id location meeting_url]).any?
      if status == ["pending", "published"]
        ([record.owner] + applicants).uniq(&:id).each do |receiver|
        emit(receiver: receiver, item: record, action: "event_approved", title: "活动已通过发布审核", body: "「#{record.title}」已发布。", actor: actor, payload: {review_receipt_id: ReviewNotifications.receipt_id(record, receiver)})
        end
      end
      return unless record.status.in?(%w[published cancelled]) && !changes.key?("id")
      cancelled = status && status.last == "cancelled"
      return unless cancelled || (changes.keys & %w[start_time end_time timezone venue_id place_id location meeting_url]).any?
      Activity.where(item: record, action: "surf/event_reminder", has_read: false).delete_all
      audience(record).order(:id).each do |user|
        emit(receiver: user, item: record, action: cancelled ? "event_cancelled" : "event_updated",
             title: cancelled ? "活动已取消" : "活动安排有变更",
             body: "「#{record.title}」#{cancelled ? '已取消，请查看后续安排；付费订单退款以实际处理结果为准。' : '时间或地点已更新，请查看最新安排。'}", actor: actor)
      end
    when Campaign
      decision = changes["review_status"]
      return unless decision && decision.first == "pending" && %w[approved rejected].include?(decision.last)
      ([record.owner] + applicants).uniq(&:id).each do |receiver|
        emit(receiver: receiver, item: record, action: "campaign_review_result", title: decision.last == "approved" ? "专题审核已通过" : "专题审核未通过",
           body: "「#{record.title}」#{decision.last == 'approved' ? '已通过审核并公开展示。' : '未通过审核：'+record.review_reason.to_s}", actor: actor, payload: {review_receipt_id: ReviewNotifications.receipt_id(record, receiver)})
      end
    when Group
      decision = changes["review_status"]
      return unless decision && decision.first == "pending" && %w[approved rejected].include?(decision.last)
      (record.memberships.active.where(role: "owner").includes(:user).map(&:user) + applicants).uniq(&:id).each do |receiver|
        emit(receiver: receiver, item: record, action: "group_review_result", title: decision.last == "approved" ? "群组审核已通过" : "群组审核未通过",
             body: "「#{record.nickname.presence || record.name}」#{decision.last == 'approved' ? '已通过审核。' : '未通过审核：'+record.review_reason.to_s}", actor: actor, payload: {review_receipt_id: ReviewNotifications.receipt_id(record, receiver)})
      end
    when Topic
      return unless changes.key?("id") && record.event && !record.deleted_at && !record.flagged?
      organizers(record.event).each do |receiver|
        next unless TopicPolicy.new(receiver, record).show?
        emit(receiver: receiver, item: record, action: "event_discussion", title: "活动收到新讨论",
             body: "「#{record.event.title}」有新讨论。", actor: record.user, key: "topic:#{record.id}")
      end
    when Comment
      return unless changes.key?("id") && record.comment_type == "star" && !record.removed && record.item_type == "Topic"
      topic = record.item
      return unless topic && !topic.deleted_at && TopicPolicy.new(record.user, topic).show? && TopicPolicy.new(topic.user, topic).show?
      emit(receiver: topic.user, item: topic, action: "topic_star", title: "帖子收到新的赞",
           body: "你的帖子收到了新的赞。", actor: record.user, key: "topic_star:#{topic.id}:#{record.user_id}")
    when Reply
      return unless changes.key?("id") && record.deleted_at.nil? && record.flagged_at.nil?
      receivers = [record.topic.user, record.reply_to&.user]
      receivers.concat(organizers(record.topic.event).to_a) if record.topic.event
      receivers.compact.uniq(&:id).each do |user|
        next unless TopicPolicy.new(user, record.topic).show?
        emit(receiver: user, item: record.topic, action: "reply", title: "收到新的回复", body: "「#{record.topic.title.presence || '社区帖子'}」有新回复。", actor: record.user, key: "reply:#{record.id}", payload: {reply_id: record.id})
      end
    when Membership
      return unless changes["role"] && !changes.key?("id")
      emit(receiver: record.user, item: record.group, action: "membership_role", title: "群组管理身份已更新", body: "你在「#{record.group.nickname.presence || record.group.name}」的身份已更新为#{ {'owner'=>'创建者','manager'=>'管理员','member'=>'成员'}[record.role] }。", actor: actor)
    when GroupInvite
      return unless status && %w[accepted cancelled revoked].include?(status.last)
      # Only results here: sent invitations already have a legacy Activity and live pending card.
      return unless status.first.in?(%w[sending requesting])
      result = if status.last == "accepted" then "已接受"
               elsif status.last == "revoked" || actor&.id == record.sender_id then "已撤回"
               elsif status.first == "requesting" && actor&.id == record.receiver_id then "已撤回"
               else "未通过" end
      users = [record.sender, record.receiver].compact.uniq(&:id)
      users.each do |user|
        emit(receiver: user, item: record.group, action: "invitation_result", title: "群组#{status.first == 'requesting' ? '加入申请' : '邀请'}#{result}",
             body: "「#{record.group.nickname.presence || record.group.name}」的#{status.first == 'requesting' ? '加入申请' : '邀请'}#{result}。", actor: actor,
             key: "invite:#{record.id}:#{status.last}", payload: {review_receipt_id: ReviewNotifications.receipt_id(record, user)})
      end
    when TicketItem
      if status && status.last == "timeout" && record.event
        emit(receiver: record.user, item: record.event, action: "payment_expired", title: "报名支付已超时", body: "「#{record.event.title}」的支付资格已到期，预留名额已释放，可重新报名。", key: "order:#{record.id}:timeout")
      end
      return unless status && status.last == "succeeded" && record.amount.to_i.positive?
      return unless record.event
      organizers(record.event).find_each do |receiver|
        emit(receiver: receiver, item: record.event, action: "payment_received", title: "活动收到报名付款", body: "#{record.user.nickname.presence || record.user.name.presence || 'Surf 成员'} 已完成「#{record.event.title}」的付款。", actor: record.user,
             key: "payment_received:#{record.id}:#{receiver.id}")
      end
      emit(receiver: record.user, item: record.event, action: "payment_result", title: "活动订单支付成功",
           body: "「#{record.event.title}」订单已确认支付，请查看报名或审核状态。", actor: nil,
           key: "order:#{record.id}:#{record.updated_at.iso8601(6)}:#{status.last}")
    when Refund
      return unless status && %w[pending succeeded failed].include?(status.last) && record.ticket_item.event
      request = record.refund_request
      if request && %w[succeeded failed].include?(status.last)
        request.update!(status: status.last)
      end
      event = record.ticket_item.event
      ([record.ticket_item.user, record.requested_by] + organizers(event).to_a).compact.uniq(&:id).each do |receiver|
        emit(receiver: receiver, item: record, action: {"failed"=>"refund_failed", "pending"=>"refund_submitted", "succeeded"=>"refund_result"}[status.last],
             title: {"pending"=>"活动退款已提交", "succeeded"=>"活动订单退款已处理", "failed"=>"退款处理失败"}[status.last],
             body: "「#{event.title}」#{ {'pending'=>'退款已提交支付平台，等待确认；确认成功后完成退出。','succeeded'=>'退款已确认，请查看订单与报名状态。','failed'=>'退款未完成，请查看订单并联系主办方。'}[status.last] }", actor: actor,
             key: "refund:#{record.id}:#{status.last}:#{receiver.id}")
      end
    end
  end

  def self.organizers(event)
    ids = event.group.memberships.active.where(role: %w[owner manager]).select(:user_id)
    roles = event.event_roles.where(role: %w[co_host custom_host group_host])
    host_groups = roles.where(item_type: "Group").select(:item_id)
    User.where(id: ids).or(User.where(id: event.owner_id))
        .or(User.where(id: roles.where(item_type: "User").select(:item_id)))
        .or(User.where(id: Membership.active.where(group_id: host_groups, role: %w[owner manager]).select(:user_id))).distinct
  end

  def self.audience(event)
    ids = event.participants.where(status: %w[attending pending awaiting_payment]).pluck(:user_id)
    ids << event.owner_id
    ids.concat(event.event_roles.where(item_type: "User").where.not(item_id: nil).pluck(:item_id))
    emails = event.event_roles.where(item_type: "User").where.not(email: [nil, ""]).pluck(:email)
    User.where(id: ids).or(User.where(email: emails)).distinct
  end

  def self.role_links(event)
    event.event_roles.where(item_type: "User").each_with_object({}) do |role, links|
      next unless role.item_id.present? || role.email.present?
      user = role.item_id.present? ? User.find_by(id: role.item_id) : User.find_by(email: role.email)
      links[user.id] = role.role if user
    end
  end

  def self.roles_changed(event, before, actor:)
    after = role_links(event)
    revision = SecureRandom.uuid
    (before.keys | after.keys).each do |id|
      next if before[id] == after[id]
      user = User.find_by(id: id)
      emit(receiver: user, item: event, action: "event_role", title: after[id] ? "你已关联到活动" : "活动角色关联已移除",
           body: after[id] ? "你已成为「#{event.title}」的#{ROLES[after[id]] || '嘉宾'}，#{event.status == 'published' ? '活动已自动加入你的日历' : '活动发布后会自动加入你的日历'}，无需再次报名。" : "你在「#{event.title}」的角色关联已移除，实际报名记录仍保留。",
           actor: actor, key: "role:#{event.id}:#{id}:#{revision}:#{after[id] || 'removed'}")
    end
  end

  def self.target(notice, user)
    if notice.receiver_id == user.id
      return {page: "review-detail", id: notice.id} if notice.action == ReviewNotifications::ACTION
      return {page: "review-detail", id: notice.payload["review_receipt_id"]} if notice.payload["review_receipt_id"].present?
    end
    content_target(notice, user)
  end

  def self.content_target(notice, user)
    item = notice.item
    case item
    when Withdrawal
      return {page: "admin-withdrawals", id: item.id} if user.active? && user.platform_admin?
      return {page: "withdrawals", id: item.group_id} if Withdrawal.may_manage?(user, item.group)
    when Event
      return {page: "event-detail", id: item.id} if EventPolicy.new(user, item).show?
    when Group
      return {page: "group-detail", id: item.id} if GroupPolicy.new(user, item).show?
    when RefundRequest, Refund
      item = item.ticket_item
      event = item.event
      if event && (item.user_id == user.id || organizers(event).exists?(id: user.id))
        return {page: "orders", id: event.id, mine: item.user_id == user.id}
      end
    when Campaign
      return {page: "campaign-detail", id: item.id} if CampaignPolicy.new(user, item).show?
    when Topic
      return {page: "post-detail", id: item.id} if TopicPolicy.new(user, item).show?
    when Participant
      return {page: "event-detail", id: item.event_id} if EventPolicy.new(user, item.event).show?
    when Membership
      return {page: "group-detail", id: item.group_id} if GroupPolicy.new(user, item.group).show?
    when GroupInvite
      return {page: "group-detail", id: item.group_id} if GroupInvitePolicy.new(user, item).view?
    end
    nil
  end
end
