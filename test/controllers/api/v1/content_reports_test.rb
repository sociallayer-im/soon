require "test_helper"

class Api::V1::ContentReportsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = create_user
    @reporter = create_user
    @admin = create_user(admin: true)
    @group = create_group(owner: @owner, discussion_enabled: true)
    @event = create_event(group: @group, owner: @owner)
  end

  test "only administrators handle reports and event moderation preserves registrations" do
    participant = create_participant(event: @event, user: @reporter, payment_status: "succeeded")
    ticket = create_ticket(event: @event)
    order = TicketItem.create!(ticket: ticket, event: @event, user: @reporter, participant: participant, status: "succeeded", amount: 100, currency: "CNY")
    post "/api/v1/content_reports", params: {target_type: "Event", target_id: @event.id, reason: "违规"}, headers: auth_headers(@reporter)
    assert_response :created
    report = ContentReport.find(json_response["id"])
    post "/api/v1/content_reports", params: {target_type: "Event", target_id: @event.id, reason: "重复"}, headers: auth_headers(@reporter)
    assert_response :conflict
    get "/api/v1/admin/content_reports", headers: auth_headers(@reporter)
    assert_response :forbidden
    post "/api/v1/admin/content_reports/#{report.id}/review", params: {decision: "hide", note: "违规"}, headers: auth_headers(@reporter)
    assert_response :forbidden
    post "/api/v1/admin/content_reports/#{report.id}/review", params: {decision: "hide", note: "违规"}, headers: auth_headers(@admin)
    assert_response :success
    assert_equal "published", @event.reload.status
    assert @event.moderated_at
    assert_not @event.registration_open?
    assert_equal "attending", participant.reload.status
    assert_equal "succeeded", participant.payment_status
    assert_equal "succeeded", order.reload.status
    assert_equal 100, order.amount
    assert_not Event.publicly_discoverable.exists?(id: @event.id)
    assert EventPolicy.new(@reporter, @event).show?
    assert_not EventPolicy.new(create_user, @event).show?
    post "/api/v1/admin/content_reports/#{report.id}/restore", params: {note: "复核通过"}, headers: auth_headers(@reporter)
    assert_response :forbidden
    post "/api/v1/admin/content_reports/#{report.id}/restore", params: {note: "复核通过"}, headers: auth_headers(@admin)
    assert_response :success
    assert_nil @event.reload.moderated_at
    assert_equal "succeeded", order.reload.status
    assert report.reload.restored_at
    post "/api/v1/admin/content_reports/#{report.id}/review", params: {decision: "dismiss", note: "重复"}, headers: auth_headers(@admin)
    assert_response :conflict
  end

  test "administrator can hide a reported post" do
    category = create_category(group: @group)
    topic = create_topic(category: category, user: @owner)
    post "/api/v1/content_reports", params: {target_type: "Topic", target_id: topic.id, reason: "不当内容"}, headers: auth_headers(@reporter)
    assert_response :created
    report_id = json_response["id"]
    get "/api/v1/admin/content_reports", headers: auth_headers(@admin)
    assert_response :success
    assert_includes json_response["data"].map { |row| row["id"] }, report_id
    post "/api/v1/admin/content_reports/#{report_id}/review", params: {decision: "hide", note: "违规"}, headers: auth_headers(@admin)
    assert_response :success
    assert topic.reload.flagged?
    assert_equal @admin.id, topic.flagged_by_id
  end

  test "report requires visible supported content and a reason" do
    post "/api/v1/content_reports", params: {target_type: "User", target_id: @owner.id, reason: "x"}, headers: auth_headers(@reporter)
    assert_response :unprocessable_entity
    post "/api/v1/content_reports", params: {target_type: "Event", target_id: @event.id, reason: " "}, headers: auth_headers(@reporter)
    assert_response :unprocessable_entity
  end
end
