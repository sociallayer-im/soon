require "test_helper"

class Api::V1::RegistrationReviewFlowTest < ActionDispatch::IntegrationTest
  setup do
    @owner = create_user
    @buyer = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner, status: "published", require_approval: true, end_time: 3.days.from_now)
    @ticket = create_ticket(event: @event, quantity: 2)
    @method = create_payment_method(item: @ticket, chain: "stripe", price: 1000)
  end

  def apply(user = @buyer, ticket = @ticket, method = @method)
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", params: {payment_method_id: method&.id}, headers: auth_headers(user)
    assert_response :success
    [Participant.find(json_response["participant"]["id"]), TicketItem.find(json_response["ticket_item"]["id"])]
  end

  def decide(participant, action = "approve", reason = nil)
    post "/api/v1/events/#{@event.id}/participants/#{participant.id}/#{action}", params: {reason: reason}, headers: auth_headers(@owner)
  end

  test "paid review holds no stock or seat until approval and confirms only after payment" do
    participant, item = apply
    assert_equal "pending", participant.status
    assert_not item.inventory_reserved?
    assert_nil item.reserved_until
    assert_equal 2, @ticket.reload.quantity
    assert_equal 0, @event.reload.participant_count
    assert_raises(TicketItem::InvalidTransition) { item.confirm_payment! }
    decide(participant)
    assert_response :success
    assert_equal "awaiting_payment", participant.reload.status
    assert_equal @owner.id, participant.reviewed_by_id
    assert_in_delta 24.hours.from_now, participant.payment_due_at, 5
    assert_equal 1, @ticket.reload.quantity
    assert_equal 0, @event.reload.participant_count
    assert_equal participant.payment_due_at, item.reload.reserved_until
    assert_not Event.agenda_for(@buyer).exists?(@event.id)
    item.confirm_payment!
    assert_equal "attending", participant.reload.status
    assert_equal 1, @event.reload.participant_count
    assert Event.agenda_for(@buyer).exists?(@event.id)
    item.reload.confirm_payment!
    assert_equal 1, @event.reload.participant_count
  end

  test "rejection requires reason, releases no unreserved stock, and allows clean reapplication" do
    participant, item = apply
    decide(participant, "reject", " ")
    assert_response :unprocessable_entity
    decide(participant, "reject", "本场面向初学者")
    assert_response :success
    assert_equal "declined", participant.reload.status
    assert_equal "本场面向初学者", participant.review_reason
    assert_equal "cancelled", item.reload.status
    assert_equal 2, @ticket.reload.quantity
    participant, item = apply
    assert_equal "pending", participant.status
    assert_nil participant.review_reason
    assert_nil participant.reviewed_at
    assert_not item.inventory_reserved?
    assert_equal 2, @ticket.reload.quantity
  end

  test "free ticket is confirmed and granted only on approval" do
    @method.destroy!
    participant, item = apply(@buyer, @ticket, nil)
    assert_equal "pending", item.status
    assert_nil item.paid_at
    decide(participant)
    assert_response :success
    assert_equal "attending", participant.reload.status
    assert_equal "succeeded", item.reload.status
    assert_equal 1, @ticket.reload.quantity
    assert_equal 1, @event.reload.participant_count
  end

  test "approval checks event capacity and ticket stock independently and rolls back" do
    @event.update!(max_participant: 1)
    first, = apply
    second, = apply(create_user)
    decide(first)
    assert_response :success
    decide(second)
    assert_response :unprocessable_entity
    assert_equal "pending", second.reload.status
    assert_equal 1, @ticket.reload.quantity
    @event.update!(max_participant: 10)
    @ticket.update!(quantity: 0)
    decide(second)
    assert_response :unprocessable_entity
    assert_equal "pending", second.reload.status
    assert_nil second.reviewed_at
  end

  test "approval deadline honors ticket cutoff and no-prepay expiry releases reservation exactly once" do
    @ticket.update!(end_time: 2.hours.from_now)
    participant, item = apply
    decide(participant)
    assert_response :success
    assert_equal @ticket.end_time, participant.reload.payment_due_at
    participant.update!(payment_due_at: 1.hour.ago)
    item.update!(reserved_until: 1.hour.ago)
    begin
      Rails.error.stub(:report, ->(e, **_) { raise e }) { TicketingSweeperJob.perform_now }
      assert_equal "timeout", item.reload.status
      assert_equal "cancelled", participant.reload.status
      assert_equal 2, @ticket.reload.quantity
      TicketingSweeperJob.perform_now
      assert_equal 2, @ticket.reload.quantity
      assert Activity.exists?(receiver: @buyer, action: "surf/payment_expired")
    end
  end

  test "applicant can withdraw under review without increasing stock" do
    participant, item = apply
    delete "/api/v1/events/#{@event.id}/participants/#{participant.id}", headers: auth_headers(@buyer)
    assert_response :no_content
    assert_equal "cancelled", participant.reload.status
    assert_equal "cancelled", item.reload.status
    assert_equal 2, @ticket.reload.quantity
  end

  test "own registrations are isolated and public attendee list hides pending and answers" do
    participant, = apply
    get "/api/v1/registrations", headers: auth_headers(@buyer)
    assert_response :success
    assert_equal [participant.id], json_response["data"].map { |row| row["id"] }
    assert_equal @event.id, json_response["data"].first["event"]["id"]
    get "/api/v1/registrations", headers: auth_headers(create_user)
    assert_empty json_response["data"]
    get "/api/v1/events/#{@event.id}/participants"
    assert_response :success
    assert_empty json_response["data"]
    get "/api/v1/events/#{@event.id}/participants", headers: auth_headers(@owner)
    assert_equal [participant.id], json_response["data"].map { |row| row["id"] }
    assert json_response["data"].first.key?("application_answers")
    assert_equal @ticket.title, json_response["data"].first["review_tickets"].first["title"]
  end

  test "notifications report request approval and reason without turning tasks into messages" do
    participant, = apply
    assert Activity.exists?(receiver: @owner, action: "surf/registration_request")
    assert SiteNotificationTasks.for(@owner).any? { |task| task[:resource_id] == participant.id }
    decide(participant)
    assert_response :success
    assert Activity.exists?(receiver: @buyer, action: "surf/registration_result")
    assert_not SiteNotificationTasks.for(@owner).any? { |task| task[:resource_id] == participant.id }
    decide(participant)
    assert_response :unprocessable_entity
    assert_equal 1, @ticket.reload.quantity
  end
  test "ticket application validates mandatory answers and manager-only answers stay protected" do
    form = create_form
    required = create_form_field(form: form, required: true, label: "参加原因")
    internal = create_form_field(form: form, for_admin: true, label: "内部备注")
    @event.update!(form_id: form.id)
    post "/api/v1/events/#{@event.id}/tickets/#{@ticket.id}/rsvp", params: {payment_method_id: @method.id}, headers: auth_headers(@buyer)
    assert_response :unprocessable_entity
    assert_equal 2, @ticket.reload.quantity
    assert_not @event.participants.exists?(user: @buyer)
    post "/api/v1/events/#{@event.id}/tickets/#{@ticket.id}/rsvp", params: {payment_method_id: @method.id, answers: [{field_id: required.id, value: "学习"}, {field_id: internal.id, value: "伪造审核意见"}]}, headers: auth_headers(@buyer)
    assert_response :success
    submission = FormSubmission.find_by!(form: form, user: @buyer)
    assert_equal [required.id], submission.form_answers.pluck(:form_field_id)
    get "/api/v1/events/#{@event.id}/participants", headers: auth_headers(@owner)
    assert_equal [{"label"=>"参加原因", "value"=>"学习"}], json_response["data"].first["application_answers"]
  end

  test "status update cannot bypass approval or ticket checkout" do
    participant, = apply
    patch "/api/v1/events/#{@event.id}/participants/#{participant.id}", params: {participant: {status: "attending"}}, headers: auth_headers(@buyer)
    assert_response :unprocessable_entity
    assert_equal "pending", participant.reload.status
    post "/api/v1/events/#{@event.id}/participants", headers: auth_headers(create_user)
    assert_response :unprocessable_entity
    assert_equal 2, @ticket.reload.quantity
  end

  test "expired approval cannot start a new payment or silently free unresolved holds" do
    participant, item = apply
    decide(participant)
    participant.update!(payment_due_at: 1.minute.ago)
    @event.update!(max_participant: 1)
    assert RegistrationReview.capacity_full?(@event), "keep hold until authoritative expiry closes remote payment"
    post "/api/v1/tickets/checkout_session", params: {ticket_item_id: item.id}, headers: auth_headers(@buyer)
    # payment feature flag may be disabled: shared gate is also tested through verify_payment.
    post "/api/v1/tickets/verify_payment", params: {ticket_item_id: item.id}, headers: auth_headers(@buyer)
    assert_response :unprocessable_entity
    assert_match "支付资格已到期", json_response["error"]
    assert_equal "awaiting_payment", participant.reload.status
  end

  test "cancelling an opened WeChat checkout closes remotely before releasing and fails closed on outage" do
    participant, item = apply
    decide(participant)
    merchant = create_wechat_pay_setting
    item.update!(payment_provider: "wechat", wechat_pay_setting_id: merchant.id, provider_ref: "prepay_test")
    WechatPayGateway.stub :query_order, nil do
      assert_raises(TicketItem::InvalidTransition) { item.cancel }
    end
    assert_equal "pending", item.reload.status
    assert_equal 1, @ticket.reload.quantity
    WechatPayGateway.stub :query_order, {"trade_state"=>"SUCCESS"} do
      assert_raises(TicketItem::InvalidTransition) { item.cancel }
    end
    closed = []
    WechatPayGateway.stub :query_order, {"trade_state"=>"NOTPAY"} do
      WechatPayGateway.stub :close_order, ->(_setting, id) { closed << id; true } do
        item.cancel
      end
    end
    assert_equal [item.id], closed
    assert_equal "cancelled", participant.reload.status
    assert_equal 2, @ticket.reload.quantity
    item.cancel
    assert_equal 2, @ticket.reload.quantity
  end

  test "approved paid email explains payment deadline without attaching admission calendar" do
    participant, = apply
    decide(participant)
    mail = EventMailer.participant_approved(participant_id: participant.id)
    assert_empty mail.attachments
    assert_match "支付成功后报名才生效", mail.text_part.body.decoded
  end

  test "switching tickets cannot bypass an existing application and unreserved orders cannot be paid" do
    participant, item = apply
    alternative = create_ticket(event: @event, need_approval: false, quantity: 5)
    @event.update!(require_approval: false)
    post "/api/v1/events/#{@event.id}/tickets/#{alternative.id}/rsvp", headers: auth_headers(@buyer)
    assert_response :unprocessable_entity
    assert_equal "pending", participant.reload.status
    assert_equal 5, alternative.reload.quantity
    participant.update!(status: "attending") # corrupt/legacy row must not make an unreserved order payable
    post "/api/v1/tickets/verify_payment", params: {ticket_item_id: item.id}, headers: auth_headers(@buyer)
    assert_response :unprocessable_entity
    assert_raises(TicketItem::InvalidTransition) { item.confirm_payment! }
    assert_equal "pending", item.reload.status
  end

end
