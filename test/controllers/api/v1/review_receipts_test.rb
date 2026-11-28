require "test_helper"

class Api::V1::ReviewReceiptsTest < ActionDispatch::IntegrationTest
  include ContentSafetyTestGateway

  setup do
    @owner = create_user
    @admin = create_user(admin: true, nickname: "审核管理员")
    @outsider = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner, status: "published", visibility: "normal")
  end

  def receipt(item, user = @owner)
    Activity.for_receiver(user).where(item: item, action: ReviewNotifications::ACTION).order(created_at: :desc, id: :desc).first!
  end

  def detail(notice, user = @owner)
    get "/api/v1/activities/#{notice.id}/review", headers: auth_headers(user)
    assert_response :success
    json_response
  end

  def submit_campaign(**attrs)
    post "/api/v1/campaigns", params: {campaign: {group_id: @group.id, title: "测试专题", introduction: "申请内容", status: "published", event_ids: [@event.id]}.merge(attrs), idempotency_key: "review_receipt_campaign_123"}, headers: auth_headers(@owner), as: :json
    assert_response :created
    Campaign.find(json_response["id"])
  end

  test "campaign submission sends its author a private idempotent receipt despite self actor" do
    campaign = submit_campaign
    notice = receipt(campaign)
    assert_equal "专题已提交审核", notice.payload["title"]
    assert_equal false, notice.has_read
    assert_equal({page: "review-detail", id: notice.id}, SiteNotifications.target(notice, @owner))
    assert_equal "pending", detail(notice)["status"]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal campaign.id, submit_campaign.id
    assert_equal 1, ReviewNotifications.receipts(campaign).count
    get "/api/v1/activities/#{notice.id}/review", headers: auth_headers(@outsider)
    assert_response :not_found
    get "/api/v1/activities/#{notice.id}/review", headers: auth_headers(@admin)
    assert_response :not_found
    get "/api/v1/activities/#{notice.id}/review"
    assert_response :unauthorized
  end

  test "campaign resubmission separates cycles and reviewer result remains on its own receipt" do
    campaign = submit_campaign
    old = receipt(campaign)
    patch "/api/v1/campaigns/#{campaign.id}", params: {campaign: {title: "修改后的专题"}}, headers: auth_headers(@owner), as: :json
    assert_response :success
    current = receipt(campaign)
    assert_not_equal old.id, current.id
    old_data = detail(old)
    assert_equal "superseded", old_data["status"]
    assert_equal "测试专题", old_data["title"]
    assert_equal current.id, old_data["latest_review_id"]
    post "/api/v1/admin/campaign_reviews/#{campaign.id}/review", params: {decision: "rejected", reason: "请完善活动说明"}, headers: auth_headers(@admin), as: :json
    assert_response :success
    data = detail(current)
    assert_equal "rejected", data["status"]
    assert_equal "请完善活动说明", data["reason"]
    assert_equal "审核管理员", data["reviewer_name"]
    assert_equal "superseded", detail(old)["status"]
    result = Activity.for_receiver(@owner).find_by!(item: campaign, action: "surf/campaign_review_result")
    assert_equal({page: "review-detail", id: current.id}, SiteNotifications.target(result, @owner))
  end

  test "group creation and rejection resubmission create receipts only after accepted writes" do
    post "/api/v1/groups", params: {group: {name: "new-review-group", nickname: "申请群组"}}, headers: auth_headers(@owner), as: :json
    assert_response :created
    group = Group.find(json_response["id"])
    old = receipt(group)
    assert_equal "pending", detail(old)["status"]
    post "/api/v1/admin/group_reviews/#{group.id}/review", params: {decision: "rejected", reason: "介绍不完整"}, headers: auth_headers(@admin), as: :json
    assert_response :success
    assert_equal "rejected", detail(old)["status"]
    post "/api/v1/groups/#{group.id}/resubmit", headers: auth_headers(@owner)
    assert_response :success
    assert_equal 2, ReviewNotifications.receipts(group).count
    assert_equal "pending", detail(receipt(group))["status"]
    assert_equal "rejected", detail(old)["status"]
    count = Activity.count
    post "/api/v1/groups", params: {group: {name: "invalid name"}}, headers: auth_headers(@owner), as: :json
    assert_response :unprocessable_entity
    assert_equal count, Activity.count
  end

  test "only events requiring review send submission receipts and approval updates their details" do
    @group.update!(require_event_approval: true, can_publish_event: "member")
    member = create_user
    create_membership(user: member, group: @group)
    payload = {group_id: @group.id, title: "待审活动", start_time: 1.day.from_now.iso8601, end_time: (1.day.from_now + 1.hour).iso8601, status: "published"}
    post "/api/v1/events", params: {event: payload}, headers: auth_headers(member), as: :json
    assert_response :created
    event = Event.find(json_response["id"])
    notice = receipt(event, member)
    assert_equal "pending", detail(notice, member)["status"]
    post "/api/v1/events/#{event.id}/approve", headers: auth_headers(@owner)
    assert_response :success
    assert_equal "approved", detail(notice, member)["status"]
    count = Activity.where(action: ReviewNotifications::ACTION).count
    post "/api/v1/events", params: {event: payload.merge(title: "草稿", status: "draft")}, headers: auth_headers(member), as: :json
    assert_response :created
    post "/api/v1/events", params: {event: payload.merge(title: "管理员直接发布")}, headers: auth_headers(@owner), as: :json
    assert_response :created
    assert_equal count, Activity.where(action: ReviewNotifications::ACTION).count
  end

  test "registration and group join applicants receive status tracking and resubmission history" do
    participant = create_participant(event: @event, user: @outsider, status: "pending")
    notice = receipt(participant, @outsider)
    participant.update!(status: "declined", review_reason: "名额已满")
    assert_equal "rejected", detail(notice, @outsider)["status"]
    participant.update!(status: "pending", review_reason: nil)
    assert_equal 2, ReviewNotifications.receipts(participant).count
    invite = GroupInvite.create!(group: @group, receiver: @outsider, status: "requesting", role: "member")
    join_notice = receipt(invite, @outsider)
    NotificationContext.set(actor: @owner) { invite.update!(status: "accepted") }
    assert_equal "approved", detail(join_notice, @outsider)["status"]
  end

  test "financial requests have private submission progress without claiming a refund has completed" do
    ticket = create_ticket(event: @event)
    order = TicketItem.create!(ticket: ticket, event: @event, user: @outsider, amount: 100, currency: "cny", status: "succeeded", payment_provider: "wechat")
    request = RefundRequest.create!(ticket_item: order, user: @outsider, status: "requested")
    notice = receipt(request, @outsider)
    data = detail(notice, @outsider)
    assert_equal "pending", data["status"]
    assert_equal 100, data["amount"]
    request.update!(status: "processing", reviewed_by: @owner)
    data = detail(notice, @outsider)
    assert_equal "approved", data["status"]
    assert_equal "processing", data["process_status"]
    withdrawal = Withdrawal.create!(group: @group, user: @owner, amount: 100, status: "pending", currency: "cny", bank_name: "PRIVATE_BANK", bank_account_name: "PRIVATE_NAME", bank_account_number: "PRIVATE_NUMBER")
    withdrawal_notice = receipt(withdrawal)
    assert_not_includes withdrawal_notice.payload.to_json, "PRIVATE_"
    NotificationContext.set(actor: @admin) { withdrawal.update!(status: "completed", processed_by: @admin, processed_at: Time.current) }
    assert_equal "approved", detail(withdrawal_notice)["status"]
    assert_equal "已结算", detail(withdrawal_notice)["status_label"]
    result = Activity.for_receiver(@owner).find_by!(item: withdrawal, action: "surf/review_result")
    assert_equal({page: "review-detail", id: withdrawal_notice.id}, SiteNotifications.target(result, @owner))
  end

  test "rollback leaves no receipt and deleted content does not erase private review history" do
    before = Activity.where(action: ReviewNotifications::ACTION).count
    Withdrawal.transaction do
      Withdrawal.create!(group: @group, user: @owner, amount: 100, status: "pending", currency: "cny", bank_name: "bank", bank_account_name: "name", bank_account_number: "number")
      raise ActiveRecord::Rollback
    end
    assert_equal before, Activity.where(action: ReviewNotifications::ACTION).count
    campaign = submit_campaign
    notice = receipt(campaign)
    campaign.destroy!
    data = detail(notice)
    assert_equal "withdrawn", data["status"]
    assert_nil data["target"]
  end
  test "expired join requests are shown as expired and ordinary messages have no review endpoint" do
    invite = GroupInvite.create!(group: @group, receiver: @outsider, status: "requesting", role: "member", expires_at: 1.hour.from_now)
    notice = receipt(invite, @outsider)
    invite.update_columns(expires_at: 1.second.ago)
    data = detail(notice, @outsider)
    assert_equal "expired", data["status"]
    assert data["reviewed_at"].present?
    message = SiteNotifications.emit(receiver: @owner, item: @event, action: "example", title: "普通消息", body: "内容")
    get "/api/v1/activities/#{message.id}/review", headers: auth_headers(@owner)
    assert_response :not_found
  end

end
