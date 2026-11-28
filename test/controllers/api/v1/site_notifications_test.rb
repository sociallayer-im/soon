require "test_helper"

class Api::V1::SiteNotificationsTest < ActionDispatch::IntegrationTest
  include ContentSafetyTestGateway

  setup do
    @owner = create_user
    @manager = create_user
    @guest = create_user
    @attendee = create_user
    @stranger = create_user
    @group = create_group(owner: @owner)
    create_membership(user: @manager, group: @group, role: "manager")
    @event = create_event(owner: @owner, group: @group, status: "published", start_time: 1.day.from_now, end_time: 1.day.from_now + 2.hours)
  end

  def tasks(user)
    get "/api/v1/activities/tasks", headers: auth_headers(user)
    assert_response :success
    json_response["data"]
  end

  test "live participant tasks deduplicate roles, remain after reading, and resolve for all managers" do
    EventRole.create!(event: @event, item: @manager, role: "co_host")
    participant = Participant.create!(event: @event, user: @attendee, status: "pending")
    assert_equal 1, tasks(@manager).count { |t| t["kind"] == "participant_review" }
    assert_empty tasks(@stranger)
    post "/api/v1/activities/mark_read", params: {all: true}, as: :json, headers: auth_headers(@manager)
    assert_equal 1, tasks(@manager).count { |t| t["kind"] == "participant_review" }
    post "/api/v1/events/#{@event.id}/participants/#{participant.id}/approve", headers: auth_headers(@owner)
    assert_response :success
    assert_empty tasks(@manager)
    notice = Activity.for_receiver(@attendee).find_by!(action: "surf/registration_result")
    assert_equal "报名审核已通过", notice.payload["title"]
    assert_nil Activity.for_receiver(@owner).find_by(action: "surf/registration_result")
    post "/api/v1/events/#{@event.id}/participants/#{participant.id}/reject", headers: auth_headers(@manager)
    assert_response :unprocessable_entity
    assert_equal "attending", participant.reload.status
    assert_equal 1, Activity.for_receiver(@attendee).where(action: "surf/registration_result").count
  end

  test "permission loss removes tasks and judges never receive moderation tasks" do
    Participant.create!(event: @event, user: @attendee, status: "pending")
    EventRole.create!(event: @event, item: @guest, role: "judge")
    assert_empty tasks(@guest)
    assert tasks(@manager).any?
    @group.memberships.find_by!(user: @manager).destroy!
    assert_empty tasks(@manager)
  end

  test "group and event approval tasks use different authorities and carry results" do
    admin = create_user(admin: true)
    pending = create_group(owner: @guest, review_status: "pending", active: false)
    assert tasks(admin).any? { |t| t["resource_id"] == pending.id && t["kind"] == "group_review" }
    assert_empty tasks(@guest)
    post "/api/v1/admin/group_reviews/#{pending.id}/review", params: {decision: "rejected", reason: "请补充介绍"}, as: :json, headers: auth_headers(admin)
    assert_response :success
    assert tasks(admin).none? { |t| t["resource_id"] == pending.id }
    assert_match "请补充介绍", Activity.for_receiver(@guest).find_by!(action: "surf/group_review_result").payload["body"]
    @event.update!(status: "pending")
    assert tasks(@manager).any? { |t| t["kind"] == "event_review" }
    post "/api/v1/events/#{@event.id}/approve", headers: auth_headers(@manager)
    assert_response :success
    assert Activity.for_receiver(@owner).exists?(action: "surf/event_approved")
  end

  test "important changes notify each affected user once and skip the acting editor" do
    Participant.create!(event: @event, user: @guest, status: "attending")
    EventRole.create!(event: @event, item: @guest, role: "speaker")
    EventRole.create!(event: @event, item: @attendee, role: "judge")
    patch "/api/v1/events/#{@event.id}", params: {event: {start_time: 2.days.from_now.iso8601, end_time: (2.days.from_now+2.hours).iso8601}}, as: :json, headers: auth_headers(@owner)
    assert_response :success
    assert_equal 1, Activity.for_receiver(@guest).where(action: "surf/event_updated").count
    assert Activity.for_receiver(@attendee).exists?(action: "surf/event_updated")
    assert_not Activity.for_receiver(@owner).exists?(action: "surf/event_updated")
    assert_not Activity.for_receiver(@stranger).exists?(action: "surf/event_updated")
    assert_no_difference "Activity.count" do
      @event.reload.update!(title: "只改标题")
    end
    @event.update!(status: "cancelled")
    assert Activity.for_receiver(@guest).exists?(action: "surf/event_cancelled")
  end

  test "role replacement keeps unchanged accounts quiet and reports add remove without invitation" do
    roles = [{item_type: "User", item_id: @guest.id, role: "speaker", display_name: "嘉宾"}]
    patch "/api/v1/events/#{@event.id}", params: {event: {title: @event.title}, event_roles: roles}, as: :json, headers: auth_headers(@owner)
    assert_response :success
    assert_equal 1, Activity.for_receiver(@guest).where(action: "surf/event_role").count
    patch "/api/v1/events/#{@event.id}", params: {event: {title: @event.title}, event_roles: roles}, as: :json, headers: auth_headers(@owner)
    assert_response :success
    assert_equal 1, Activity.for_receiver(@guest).where(action: "surf/event_role").count
    patch "/api/v1/events/#{@event.id}", params: {event: {title: @event.title}, event_roles: []}, as: :json, headers: auth_headers(@owner)
    assert_response :success
    assert_equal 2, Activity.for_receiver(@guest).where(action: "surf/event_role").count
    assert_not GroupInvite.where(receiver: @guest).exists?
  end

  test "station reminder excludes unpaid declined cancelled users and rechecks cancellation" do
    @event.update!(start_time: 1.hour.from_now, end_time: 3.hours.from_now)
    Participant.create!(event: @event, user: @attendee, status: "attending", payment_status: "pending")
    EventRole.create!(event: @event, item: @guest, role: "judge")
    2.times { SiteNotificationReminderJob.perform_now }
    assert_equal 1, Activity.for_receiver(@guest).where(action: "surf/event_reminder").count
    assert_not Activity.for_receiver(@attendee).exists?(action: "surf/event_reminder")
    @event.update!(status: "cancelled")
    assert_not Activity.for_receiver(@guest).exists?(action: "surf/event_reminder")
    assert_no_difference "Activity.where(action: 'surf/event_reminder').count" do
      SiteNotificationReminderJob.perform_now
    end
  end

  test "messages paginate, mark all is receiver scoped and deleted target has no link" do
    3.times { |i| SiteNotifications.emit(receiver: @guest, item: @event, action: "test", title: "消息", body: "正文", key: "test#{i}") }
    other = SiteNotifications.emit(receiver: @stranger, item: @event, action: "test", title: "其他消息", body: "正文")
    get "/api/v1/activities", params: {limit: 1}, headers: auth_headers(@guest)
    assert_response :success
    assert_equal 1, json_response["data"].size
    assert_equal "event-detail", json_response["data"].first.dig("target", "page")
    post "/api/v1/activities/mark_read", params: {all: true}, as: :json, headers: auth_headers(@guest)
    assert_not Activity.for_receiver(@guest).unread.exists?
    assert_not other.reload.has_read
    @event.destroy!
    get "/api/v1/activities", headers: auth_headers(@guest)
    assert_nil json_response["data"].first["target"]
    get "/api/v1/activities/tasks"
    assert_response :unauthorized
  end

  test "notifications roll back with failed business transaction and dedup keys are enforced" do
    assert_no_difference "Activity.count" do
      Event.transaction do
        @event.update!(status: "cancelled")
        raise ActiveRecord::Rollback
      end
    end
    2.times { SiteNotifications.emit(receiver: @guest, item: @event, action: "test", title: "测试", body: "一次", key: "same") }
    assert_equal 1, Activity.where(receiver: @guest, notification_key: "same").count
  end

  test "group requests disappear after approval and notify applicant" do
    invite = GroupInvite.create!(group: @group, receiver: @guest, status: "requesting", role: "member", expires_at: 1.day.from_now)
    assert tasks(@manager).any? { |t| t["kind"] == "group_request" }
    post "/api/v1/groups/#{@group.id}/group_invites/#{invite.id}/accept_request", headers: auth_headers(@manager)
    assert_response :success
    assert_empty tasks(@manager)
    assert Activity.for_receiver(@guest).exists?(action: "surf/invitation_result")
  end

  test "replies notify author and referenced user once without copying private contents" do
    category = create_category(group: @group)
    topic = create_topic(category: category, user: @guest)
    first = create_reply(topic: topic, user: @guest)
    create_reply(topic: topic, user: @attendee, reply_to: first, content: "私人正文不会进入提醒")
    notices = Activity.for_receiver(@guest).where(action: "surf/reply")
    assert_equal 1, notices.count
    assert_not_includes notices.first.payload["body"], "私人正文"
  end
  test "payment and each partial refund notify only after authoritative settlement" do
    ticket = create_ticket(event: @event)
    order = TicketItem.create!(ticket: ticket, event: @event, user: @attendee, ticket_type: "event", status: "pending", amount: 100, currency: "cny")
    assert_not Activity.for_receiver(@attendee).exists?(action: "surf/payment_result")
    order.update!(status: "succeeded")
    assert_equal 1, Activity.for_receiver(@attendee).where(action: "surf/payment_result").count
    order.update!(status: "succeeded")
    assert_equal 1, Activity.for_receiver(@attendee).where(action: "surf/payment_result").count
    2.times do
      refund = order.refunds.create!(requested_by: @owner, amount: 10, currency: "cny", status: "pending", full_refund: false)
      refund.update!(status: "succeeded")
      order.update!(status: "partially_refunded")
    end
    assert_equal 2, Activity.for_receiver(@attendee).where(action: "surf/refund_result").count
  end

  test "private target is reauthorized and unread summary includes only receiver data" do
    category = create_category(group: @group, visibility: "member")
    create_membership(user: @guest, group: @group)
    topic = create_topic(category: category, user: @owner)
    SiteNotifications.emit(receiver: @guest, item: topic, action: "reply", title: "新回复", body: "查看帖子", key: "private")
    get "/api/v1/activities", headers: auth_headers(@guest)
    assert_equal "post-detail", json_response["data"].first.dig("target", "page")
    @group.memberships.find_by!(user: @guest).destroy!
    get "/api/v1/activities", headers: auth_headers(@guest)
    assert_nil json_response["data"].first["target"]
    get "/api/v1/activities/summary", headers: auth_headers(@guest)
    assert_response :success
    assert_equal 1, json_response["unread"]
    assert_equal 0, json_response["tasks"]
  end

  test "pending invitation tasks expire and cannot undo another manager acceptance" do
    invite = GroupInvite.create!(group: @group, receiver: @guest, status: "requesting", role: "member", expires_at: 1.day.ago)
    assert_empty tasks(@manager)
    invite.update!(expires_at: 1.day.from_now)
    post "/api/v1/groups/#{@group.id}/group_invites/#{invite.id}/accept_request", headers: auth_headers(@manager)
    assert_response :success
    delete "/api/v1/groups/#{@group.id}/group_invites/#{invite.id}", headers: auth_headers(@owner)
    assert_response :conflict
    assert_equal "accepted", invite.reload.status
  end

  test "unread activity edits coalesce but new changes after reading notify again" do
    Participant.create!(event: @event, user: @guest, status: "attending")
    2.times { @event.update!(start_time: @event.start_time + 1.minute, end_time: @event.end_time + 1.minute) }
    updates = Activity.for_receiver(@guest).where(action: "surf/event_updated")
    assert_equal 1, updates.count
    updates.first.update!(has_read: true)
    @event.update!(start_time: @event.start_time + 1.minute, end_time: @event.end_time + 1.minute)
    assert_equal 2, updates.count
    assert_equal 1, updates.unread.count
  end

end
