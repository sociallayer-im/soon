require "test_helper"

class Api::V1::RefundRequestsTest < ActionDispatch::IntegrationTest
  setup do
    ENV["WECHAT_PAY_ENABLED"] = "true"
    @owner = create_user
    @manager = create_user
    @buyer = create_user
    @stranger = create_user
    @group = create_group(owner: @owner)
    create_membership(group: @group, user: @manager, role: "manager")
    @event = create_event(group: @group, owner: @owner, start_time: 1.day.from_now, end_time: 1.day.from_now + 2.hours)
    @ticket = create_ticket(event: @event, quantity: 5)
    @participant = create_participant(event: @event, user: @buyer)
    @merchant = create_wechat_pay_setting
    @item = TicketItem.create!(ticket: @ticket, event: @event, participant: @participant, user: @buyer, status: "succeeded", payment_provider: "wechat", txhash: "wx_captured", wechat_pay_setting_id: @merchant.id, amount: 100, currency: "cny", ticket_type: "event")
  end
  teardown { ENV.delete("WECHAT_PAY_ENABLED") }

  def submit(user = @buyer)
    post "/api/v1/tickets/#{@item.id}/refund_requests", params: {reason: "行程变更"}, headers: auth_headers(user), as: :json
  end

  def approve(request, user = @owner)
    post "/api/v1/tickets/#{@item.id}/refund", params: {refund_request_id: request.id, amount: 1}, headers: auth_headers(user), as: :json
  end

  test "confirmed signup and captured payment notify organizers and managers once" do
    [@owner, @manager].each do |user|
      assert_equal 1, Activity.for_receiver(user).where(action: "surf/registration_received").count
      assert_equal 1, Activity.for_receiver(user).where(action: "surf/payment_received").count
    end
    @item.update!(status: "succeeded")
    assert_equal 1, Activity.for_receiver(@owner).where(action: "surf/payment_received").count
    assert_not Activity.for_receiver(@stranger).exists?(action: %w[surf/registration_received surf/payment_received])
  end

  test "buyer request is idempotent, keeps admission, notifies owners and managers, and creates owner task" do
    submit(@stranger)
    assert_response :forbidden
    submit
    assert_response :created
    id = json_response["id"]
    submit
    assert_response :created
    assert_equal id, json_response["id"]
    assert_equal 1, RefundRequest.count
    assert_equal "attending", @participant.reload.status
    assert_equal 0, Refund.count
    [@owner, @manager].each do |user|
      notice = Activity.for_receiver(user).find_by!(item: RefundRequest.find(id), action: "surf/refund_application")
      assert_equal "orders", SiteNotifications.target(notice, user)[:page]
    end
    assert_equal 1, SiteNotificationTasks.for(@owner).count { |t| t[:kind] == "refund_request" }
    assert_not SiteNotificationTasks.for(@manager).any? { |t| t[:kind] == "refund_request" }
    get "/api/v1/events/#{@event.id}", headers: auth_headers(@buyer)
    assert_equal "requested", json_response.dig("current_participant", "refund_request_status")
    assert_equal true, json_response.dig("current_participant", "requires_refund_on_exit")
  end

  test "only captured paid orders before start qualify" do
    @event.update!(start_time: 1.hour.ago)
    submit
    assert_response :unprocessable_entity
    @event.update!(start_time: 1.day.from_now)
    @item.update!(amount: 0)
    submit
    assert_response :unprocessable_entity
    assert_equal 0, RefundRequest.count
  end

  test "rejection requires organizer permission and explanation and preserves admission" do
    submit
    request = RefundRequest.last
    post "/api/v1/refund_requests/#{request.id}/reject", params: {reason: "拒绝"}, headers: auth_headers(@manager), as: :json
    assert_response :forbidden
    post "/api/v1/refund_requests/#{request.id}/reject", headers: auth_headers(@owner), as: :json
    assert_response :unprocessable_entity
    post "/api/v1/refund_requests/#{request.id}/reject", params: {reason: "请联系主办方"}, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal "rejected", request.reload.status
    assert_equal "attending", @participant.reload.status
    assert_empty SiteNotificationTasks.for(@owner).select { |t| t[:kind] == "refund_request" }
    assert Activity.for_receiver(@buyer).exists?(item: request, action: "surf/refund_application")
  end

  test "approval refunds full balance, stays seated until callback, and cannot dispatch twice" do
    submit
    request = RefundRequest.last
    approve(request, @manager)
    assert_response :forbidden
    calls = 0
    WechatPayGateway.stub(:create_refund, ->(_setting, _item, refund) {calls += 1; assert_equal 100, refund.amount; {"refund_id"=>"wx_refund"}}) do
      approve(request)
      assert_response :success
      approve(request)
      assert_response :unprocessable_entity
    end
    assert_equal 1, calls
    assert_equal "processing", request.reload.status
    assert_equal "attending", @participant.reload.status
    @item.apply_refund_success!(request.refund, source: "test")
    assert_equal "succeeded", request.reload.status
    assert_equal "cancelled", @participant.reload.status
    [@owner, @manager, @buyer].each { |u| assert Activity.for_receiver(u).exists?(action: "surf/refund_result") }
  end

  test "unreachable provider keeps request processing; failed callback keeps admission and allows retry" do
    submit
    request = RefundRequest.last
    WechatPayGateway.stub(:create_refund, ->(*) {raise WechatPayGateway::Unreachable, "timeout"}) {approve(request)}
    assert_response :success
    assert_equal "processing", request.reload.status
    assert_equal "pending", request.refund.status
    request.refund.update!(status: "failed", error: "gateway refused")
    assert_equal "failed", request.reload.status
    assert_equal "attending", @participant.reload.status
    submit
    assert_response :created
    assert_not_equal request.id, json_response["id"]
  end

  test "order views show requests and buyer can apply but only organizer can decide" do
    submit
    get "/api/v1/tickets/list", params: {event_id: @event.id, mine: true, include_refunds: true, page: 1}, headers: auth_headers(@buyer)
    row = json_response["data"].sole
    assert_equal false, row["can_request_refund"]
    assert_equal false, row["refund_requests"].sole["can_review"]
    get "/api/v1/tickets/list", params: {event_id: @event.id, page: 1}, headers: auth_headers(@owner)
    assert_equal true, json_response["data"].sole["refund_requests"].sole["can_review"]
  end
end
