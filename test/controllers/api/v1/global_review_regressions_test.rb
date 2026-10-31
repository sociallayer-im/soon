require "test_helper"
class Api::V1::GlobalReviewRegressionsTest < ActionDispatch::IntegrationTest
  test "publishing a draft enters review and pending content is private" do
    owner = create_user; member = create_user
    group = create_group(owner: owner, require_event_approval: true, can_publish_event: "member")
    create_membership(user: member, group: group)
    event = create_event(group: group, owner: member, status: "draft")
    patch "/api/v1/events/#{event.id}", params: {event: {status: "published"}}, headers: auth_headers(member), as: :json
    assert_response :ok
    assert_equal "pending", event.reload.status
    assert Activity.exists?(receiver: member, item: event, action: ReviewNotifications::ACTION)
    get "/api/v1/events/#{event.id}"
    assert_response :forbidden
    get "/api/v1/events/#{event.id}/event_roles", headers: auth_headers(create_user)
    assert_response :forbidden
    get "/api/v1/events/#{event.id}", headers: auth_headers(owner)
    assert_response :ok
  end

  test "a judge cannot grant editing roles while authorized role changes notify the assignee" do
    owner = create_user; judge = create_user; target = create_user
    group = create_group(owner: owner); event = create_event(group: group, owner: owner)
    create_event_role(event: event, item: judge, role: "judge")
    payload = {event_role: {item_type: "User", item_id: target.id, role: "co_host"}}
    post "/api/v1/events/#{event.id}/event_roles", params: payload, headers: auth_headers(judge), as: :json
    assert_response :forbidden
    post "/api/v1/events/#{event.id}/event_roles", params: payload, headers: auth_headers(owner), as: :json
    assert_response :created
    role_id = json_response["id"]
    assert_equal 1, Activity.where(receiver: target, item: event, action: "surf/event_role").count
    delete "/api/v1/events/#{event.id}/event_roles/#{role_id}", headers: auth_headers(owner)
    assert_response :no_content
    assert_equal 2, Activity.where(receiver: target, item: event, action: "surf/event_role").count
  end

  test "last owner cannot demote itself but ownership can be transferred" do
    owner = create_user; group = create_group(owner: owner)
    membership = group.memberships.find_by!(user: owner)
    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}", params: {membership: {role: "member"}}, headers: auth_headers(owner), as: :json
    assert_response :unprocessable_entity
    assert_equal "owner", membership.reload.role
    create_membership(user: create_user, group: group, role: "owner")
    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}", params: {membership: {role: "member"}}, headers: auth_headers(owner), as: :json
    assert_response :ok
  end

  test "inactive users and inactive or expired memberships have no write powers" do
    owner = create_user; manager = create_user; group = create_group(owner: owner)
    membership = create_membership(user: manager, group: group, role: "manager", active: false)
    assert_not GroupPolicy.new(manager, group).manage?
    assert_not Withdrawal.may_manage?(manager, group)
    membership.update!(active: true, expires_at: 1.day.ago)
    assert_not GroupPolicy.new(manager, group).manage?
    manager.update!(active: false)
    post "/api/v1/follows", params: {target_type: "User", target_id: owner.id}, headers: auth_headers(manager), as: :json
    assert_response :unauthorized
  end

  test "pending refunds reserve withdrawal funds and prevent stale settlement" do
    owner = create_user; admin = create_user(admin: true); group = create_group(owner: owner)
    event = create_event(group: group, owner: owner); ticket = create_ticket(event: event)
    item = TicketItem.create!(ticket: ticket, event: event, user: create_user, ticket_type: "event", status: "succeeded", amount: 10_000, currency: "cny", payment_provider: "wechat")
    withdrawal = Withdrawal.create!(group: group, user: owner, amount: 9_600, currency: "cny", status: "pending", bank_name: "Bank", bank_account_name: "Test", bank_account_number: "1234")
    refund = item.refunds.create!(requested_by: owner, amount: 10_000, currency: "cny", status: "pending", full_refund: true)
    assert_equal 0, Withdrawal.available_balance(group)
    patch "/api/v1/admin/withdrawals/#{withdrawal.id}", params: {status: "completed"}, headers: auth_headers(admin), as: :json
    assert_response :unprocessable_entity
    assert_equal "pending", withdrawal.reload.status
    refund.update!(status: "failed")
    patch "/api/v1/admin/withdrawals/#{withdrawal.id}", params: {status: "completed"}, headers: auth_headers(admin), as: :json
    assert_response :ok
  end

  test "merge preserves refund applicant and reviewer references" do
    owner = create_user; from = create_user; into = create_user; group = create_group(owner: owner)
    event = create_event(group: group, owner: owner); ticket = create_ticket(event: event)
    item = TicketItem.create!(ticket: ticket, event: event, user: from, ticket_type: "event", status: "succeeded", amount: 100, currency: "cny", payment_provider: "wechat")
    request = RefundRequest.create!(ticket_item: item, user: from, reviewed_by: from, status: "rejected")
    campaign = Campaign.create!(group: group, owner: owner, title: "专题", introduction: "说明", status: "published", review_status: "approved", reviewed_by_id: from.id)
    log = campaign.campaign_review_logs.create!(reviewer: from, decision: "approved")
    UserMerger.call(from: from, into: into)
    assert_not User.exists?(from.id)
    assert_equal into.id, request.reload.user_id
    assert_equal into.id, request.reviewed_by_id
    assert_equal into.id, campaign.reload.reviewed_by_id
    assert_equal into.id, log.reload.reviewer_id
  end

  test "actual submitter receives decision and reviewer receives new submission" do
    owner = create_user; manager = create_user; admin = create_user(admin: true)
    group = create_group(owner: owner); create_membership(user: manager, group: group, role: "manager")
    campaign = Campaign.create!(group: group, owner: owner, title: "专题", introduction: "说明", status: "published", review_status: "pending")
    receipt = ReviewNotifications.submitted(campaign, applicant: manager, cycle: "test")
    assert Activity.exists?(receiver: admin, item: campaign, action: "surf/review_requested")
    NotificationContext.set(actor: admin) { campaign.update!(review_status: "approved") }
    result = Activity.find_by!(receiver: manager, item: campaign, action: "surf/campaign_review_result")
    assert_equal receipt.id, result.payload["review_receipt_id"]
    assert_equal "approved", receipt.reload.payload.dig("review", "status")
  end

  test "awaiting payment users receive schedule changes" do
    owner = create_user; buyer = create_user; group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    create_participant(event: event, user: buyer, status: "awaiting_payment", payment_status: "pending")
    NotificationContext.set(actor: owner) { event.update!(start_time: event.start_time + 1.hour) }
    assert Activity.exists?(receiver: buyer, item: event, action: "surf/event_updated")
  end

  test "task count does not hydrate records and task pages are bounded" do
    admin = create_user(admin: true)
    23.times { create_group(review_status: "pending", active: false) }
    assert_equal 23, SiteNotificationTasks.count(admin)
    get "/api/v1/activities/tasks", params: {page: 1, limit: 20}, headers: auth_headers(admin)
    assert_response :ok
    first = json_response["data"].map { |row| row["id"] }
    assert_equal 20, first.length
    assert_equal 23, json_response.dig("meta", "total")
    get "/api/v1/activities/tasks", params: {page: 2, limit: 20}, headers: auth_headers(admin)
    assert_equal 3, json_response["data"].length
    assert_empty first & json_response["data"].map { |row| row["id"] }
  end

  test "compact group detail limits member and venue previews and preserves my membership" do
    owner = create_user; group = create_group(owner: owner)
    8.times { create_membership(user: create_user, group: group); create_venue(group: group, owner: owner) }
    get "/api/v1/groups/#{group.id}", params: {compact: true}, headers: auth_headers(owner)
    assert_response :ok
    assert_equal [owner.id], json_response["memberships"].map { |row| row.dig("user", "id") }
    assert_equal 5, json_response["member_preview"].length
    assert_equal 5, json_response["venues"].length
    assert_equal 2, json_response["venue_next_page"]
    get "/api/v1/venues", params: {group_id: group.id, page: 2, limit: 5}
    assert_response :ok
    assert_equal 3, json_response["data"].length
  end
end
