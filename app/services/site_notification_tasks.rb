# Tasks are a live permission projection. Count in SQL and hydrate only a page.
class SiteNotificationTasks
  MODELS = {"withdrawal_request"=>Withdrawal, "campaign_review"=>Campaign, "group_review"=>Group,
    "event_review"=>Event, "participant_review"=>Participant, "group_request"=>GroupInvite, "refund_request"=>RefundRequest}.freeze

  def self.sources(user)
    managed = user.memberships.active.where(role: %w[owner manager]).select(:group_id)
    editable = Event.where(owner_id: user.id).or(Event.where(group_id: managed))
      .or(Event.where(id: EventRole.linked_to(user).where(role: EventPolicy::EDITOR_ROLES).select(:event_id)))
    refund_events = Event.where(owner_id: user.id).or(Event.where(id: EventRole.where(item_type: "User", item_id: user.id, role: "co_host").select(:event_id)))
    refundable = TicketItem.where(event_id: refund_events.select(:id)).or(TicketItem.where(ticket_type: "group", group_id: user.memberships.active.where(role: "owner").select(:group_id)))
    scopes = {
      "event_review"=>Event.where(status: "pending", group_id: managed),
      "participant_review"=>Participant.where(status: "pending", event_id: editable.where("events.status IS NULL OR events.status NOT IN (?)", %w[cancelled archived draft]).select(:id)),
      "group_request"=>GroupInvite.where(group_id: managed, status: "requesting").where("expires_at IS NULL OR expires_at > ?", Time.current),
      "refund_request"=>RefundRequest.where(status: "requested", ticket_item_id: refundable.where.not(event_id: nil).select(:id))
    }
    if user.platform_admin?
      scopes.merge!("withdrawal_request"=>Withdrawal.where(status: "pending"),
        "campaign_review"=>Campaign.where(status: "published", review_status: "pending"), "group_review"=>Group.where(review_status: "pending"))
    end
    scopes
  end

  def self.count(user)
    sources(user).values.sum(&:count)
  end

  def self.page(user, page: 1, limit: 20)
    scopes = sources(user)
    union = scopes.map { |kind, scope| scope.reselect("#{scope.klass.table_name}.id, #{scope.klass.table_name}.created_at, '#{kind}' AS kind").reorder(nil).to_sql }.join(" UNION ALL ")
    keys = ApplicationRecord.connection.select_all("SELECT * FROM (#{union}) tasks ORDER BY created_at ASC, id ASC, kind ASC LIMIT #{Integer(limit)} OFFSET #{(Integer(page)-1)*Integer(limit)}")
    records = keys.group_by { |row| row["kind"] }.to_h do |kind, rows|
      scope = MODELS.fetch(kind).where(id: rows.map { |row| row["id"] })
      scope = scope.includes(:group) if kind == "withdrawal_request"
      scope = scope.includes(:group, :receiver) if kind == "group_request"
      scope = scope.includes(:event, :user) if kind == "participant_review"
      scope = scope.includes(ticket_item: :event) if kind == "refund_request"
      [kind, scope.index_by(&:id)]
    end
    keys.filter_map { |row| item = records[row["kind"]][row["id"]]; build(row["kind"], item) if item }
  end

  # Compatibility for internal callers/tests; HTTP uses bounded .page instead.
  def self.for(user)
    page(user, limit: [count(user), 1].max)
  end

  def self.build(kind, item)
    title, body, page, id = case kind
    when "withdrawal_request" then ["提现申请待处理", "#{item.group.nickname.presence || item.group.name} · ¥#{format('%.2f', item.amount / 100.0)}", "admin-withdrawals", item.id]
    when "campaign_review" then ["专题等待审核", item.title, "campaign-detail", item.id]
    when "group_review" then ["群组等待审核", item.nickname.presence || item.name, "group-detail", item.id]
    when "event_review" then ["活动等待发布审核", item.title, "event-detail", item.id]
    when "participant_review" then ["报名申请待审核", "#{item.user.nickname.presence || item.user.name.presence || 'Surf 成员'} 申请参加「#{item.event.title}」", "event-detail", item.event_id]
    when "group_request" then ["加入群组申请待审核", "#{item.receiver&.nickname.presence || item.receiver&.name.presence || 'Surf 成员'} 申请加入「#{item.group.nickname.presence || item.group.name}」", "group-detail", item.group_id]
    when "refund_request" then ["退出与退款申请待处理", item.ticket_item.event.title, "orders", item.ticket_item.event_id]
    end
    {id: "#{kind}:#{item.id}", kind: kind, resource_id: item.id, title: title, body: body,
      created_at: item.created_at.iso8601, target: {page: page, id: id}, event_id: item.try(:event_id), group_id: item.try(:group_id)}
  end
end
