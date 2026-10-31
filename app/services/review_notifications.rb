# Applicant receipts live in the existing private Activity ledger. No extra
# table or broad list scan; (item_type,item_id) already has an index.
class ReviewNotifications
  ACTION = "surf/review_submitted"
  LABELS = {"Campaign"=>"专题", "Group"=>"群组", "Event"=>"活动发布", "Participant"=>"报名申请", "GroupInvite"=>"加入群组申请", "RefundRequest"=>"退款申请", "Withdrawal"=>"提现申请"}.freeze
  STATUSES = {"pending"=>"待审核", "approved"=>"已通过", "rejected"=>"未通过", "withdrawn"=>"已撤回", "superseded"=>"已重新提交", "expired"=>"已过期"}.freeze

  def self.receipts(record)
    Activity.where(item: record, action: ACTION)
  end

  def self.pending?(record)
    case record
    when Campaign then record.status == "published" && record.review_status == "pending"
    when Group then record.review_status == "pending"
    when GroupInvite then record.status == "requesting"
    when RefundRequest then record.status == "requested"
    else record.status == "pending"
    end
  end

  def self.title(record)
    case record
    when Campaign, Event then record.title
    when Group then record.nickname.presence || record.name
    when Participant then record.event.title
    when RefundRequest then record.ticket_item.event&.title || "活动退款"
    else record.group.nickname.presence || record.group.name
    end
  end

  def self.submitted(record, applicant:, cycle: nil)
    return unless applicant && LABELS.key?(record.class.name) && pending?(record)
    cycle ||= record.updated_at.iso8601(6)
    key = "review-submitted:#{record.class.name}:#{record.id}:#{cycle}:#{applicant.id}"
    existing = receipts(record).find_by(receiver_id: applicant.id, notification_key: key)
    return existing if existing
    finish(record, "superseded", reason: "内容已重新提交，本次申请已由新的申请替代。")
    label = LABELS.fetch(record.class.name)
    text = case record
    when Campaign then record.introduction
    when Group then record.bio
    when Event then record.content
    end
    review = {kind: record.class.name, title: title(record), content: text.to_s.truncate(2000), status: "pending", submitted_at: Time.current.iso8601}
    if record.is_a?(Withdrawal)
      review.merge!(amount: record.amount, currency: record.currency)
    elsif record.is_a?(RefundRequest)
      order = record.ticket_item
      review.merge!(amount: order.amount - order.refunds.where(status: "succeeded").sum(:amount), currency: order.currency, application_reason: record.reason)
    end
    receipt = SiteNotifications.emit(receiver: applicant, item: record, actor: applicant, allow_self: true,
      action: "review_submitted", title: "#{label}已提交审核", body: "「#{title(record)}」已提交，等待管理员处理。点击查看审核详情。", key: key,
      payload: {review: review})
    if record.is_a?(Campaign) || record.is_a?(Group) || record.is_a?(Event)
      reviewers = if record.is_a?(Event)
        User.where(id: record.group.memberships.active.where(role: %w[owner manager]).select(:user_id))
      else
        User.where("admin = TRUE OR ? = ANY(permissions)", "admin")
      end
      reviewers.where(active: true).find_each do |reviewer|
        SiteNotifications.emit(receiver: reviewer, item: record, actor: applicant,
          action: "review_requested", title: "#{label}等待审核", body: "「#{title(record)}」已提交，请查看并处理。",
          key: "review-requested:#{receipt.id}:#{reviewer.id}")
      end
    end
    receipt
  end

  def self.receipt_id(record, receiver)
    return unless receiver
    receipts(record).where(receiver: receiver).order(created_at: :desc, id: :desc).pick(:id)
  end

  def self.finish(record, status, actor: nil, reason: nil)
    receipts(record).where("payload -> 'review' ->> 'status' = ?", "pending").find_each do |notice|
      review = notice.payload.fetch("review").merge("status"=>status, "reviewed_at"=>Time.current.iso8601,
        "reason"=>reason.presence, "reviewer_name"=>actor && (actor.nickname.presence || actor.name.presence || "管理员"))
      notice.update!(payload: notice.payload.merge("review"=>review))
      # Withdrawal previously only notified administrators. Its applicant also
      # needs the result; other kinds already have result messages.
      if record.is_a?(Withdrawal) && %w[approved rejected].include?(status)
        SiteNotifications.emit(receiver: notice.receiver, item: record, actor: actor, allow_self: true,
          action: "review_result", title: "提现申请#{status == 'approved' ? '已结算' : '未通过'}", body: "请查看提现审核详情。",
          key: "review-result:#{notice.id}:#{status}", payload: {review_receipt_id: notice.id})
      end
    end
  end

  def self.changed(record, changes, actor:)
    status = changes["status"]
    case record
    when Campaign, Group
      decision = changes["review_status"]
      finish(record, decision.last, actor: actor, reason: record.review_reason) if decision&.first == "pending" && %w[approved rejected].include?(decision.last)
      finish(record, "withdrawn", actor: actor, reason: "专题已撤回公开发布。") if record.is_a?(Campaign) && status && record.status != "published"
    when Event
      if status&.first == "pending" && status.last != "pending"
        finish(record, status.last == "published" ? "approved" : "withdrawn", actor: actor)
      end
    when Participant
      submitted(record, applicant: record.user) if record.status == "pending" && (changes.key?("id") || status&.first != "pending" && status&.last == "pending")
      if status&.first == "pending" && status.last != "pending"
        result = {"attending"=>"approved", "awaiting_payment"=>"approved", "declined"=>"rejected"}.fetch(status.last, "withdrawn")
        finish(record, result, actor: actor, reason: record.review_reason)
      end
    when GroupInvite
      submitted(record, applicant: record.receiver) if record.status == "requesting" && (changes.key?("id") || status&.last == "requesting" && status.first != "requesting")
      if status&.first == "requesting" && status.last != "requesting"
        result = record.expired? ? "expired" : status.last == "accepted" ? "approved" : actor&.id == record.receiver_id ? "withdrawn" : "rejected"
        finish(record, result, actor: actor)
      end
    when RefundRequest
      submitted(record, applicant: record.user) if record.status == "requested" && changes.key?("id")
      if status&.first == "requested" && %w[processing rejected].include?(status.last)
        finish(record, status.last == "processing" ? "approved" : "rejected", actor: actor, reason: record.review_reason)
      end
    when Withdrawal
      submitted(record, applicant: record.user) if record.status == "pending" && changes.key?("id")
      if status&.first == "pending" && %w[completed rejected].include?(status.last)
        finish(record, status.last == "completed" ? "approved" : "rejected", actor: actor, reason: record.note)
      end
    end
  end

  def self.detail(notice, viewer)
    review = notice.payload.fetch("review").dup
    item = notice.item
    if review["status"] == "pending"
      review["status"] = "withdrawn" unless item
      if item.is_a?(GroupInvite) && item.expired?
        review.merge!("status"=>"expired", "reviewed_at"=>item.expires_at.iso8601, "reason"=>"申请已超过有效期，请重新申请。")
      end
    end
    target = SiteNotifications.content_target(notice, viewer) if item
    target = nil if item.is_a?(Group) && item.review_status != "approved" && !GroupPolicy.new(viewer, item).manage?
    latest = Activity.for_receiver(viewer).where(item_type: notice.item_type, item_id: notice.item_id, action: ACTION).order(created_at: :desc, id: :desc).first
    review.merge("id"=>notice.id, "kind_label"=>LABELS[review["kind"]], "status_label"=>(review["kind"] == "Withdrawal" && review["status"] == "approved" ? "已结算" : STATUSES[review["status"]]),
      "target"=>target, "latest_review_id"=>latest && latest.id != notice.id ? latest.id : nil,
      "process_status"=>item.is_a?(RefundRequest) ? item.status : nil)
  end
end
