require "test_helper"

class Api::V1::RegistrationEntryPointsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = create_user
    @user = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner, status: "published")
    @base = "/api/v1/events/#{@event.id}/participants"
  end

  test "team registration list batch loads event roles and hides invitation emails" do
    4.times do
      event = create_event(group: @group, owner: @owner)
      event.event_roles.create!(item_type: "User", role: "speaker", display_name: "嘉宾", email: "private@example.com")
    end
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:cached] }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get "/api/v1/registrations", params: {team: true}, headers: auth_headers(@owner)
    end
    assert_response :success
    role_selects = queries.grep(/SELECT "event_roles"\.\* FROM "event_roles"/i)
    assert_operator role_selects.length, :<=, 1
    assert_not response.body.include?("private@example.com")
    assert response.body.include?("嘉宾")
  end

  test "no self update status can promote an unconfirmed registration" do
    p = create_participant(event: @event, user: @user)
    %w[pending awaiting_payment declined cancelled maybe].each do |status|
      p.update!(status: status)
      patch "#{@base}/#{p.id}", params: {participant: {status: "attending"}}, headers: auth_headers(@user)
      assert_response :unprocessable_entity
      assert_equal status, p.reload.status
      assert_equal 0, @event.reload.participant_count
    end
  end

  test "legacy patch cancellation closes pending orders and returns inventory once" do
    p = create_participant(event: @event, user: @user, status: "awaiting_payment")
    ticket = create_ticket(event: @event, quantity: 0)
    item = TicketItem.create!(ticket: ticket, event: @event, user: @user, participant: p,
      status: "pending", amount: 100, ticket_type: "event", inventory_reserved: true)
    2.times do
      patch "#{@base}/#{p.id}", params: {participant: {status: "cancelled"}}, headers: auth_headers(@user)
      assert_response :success
    end
    assert_equal "cancelled", item.reload.status
    assert_equal 1, ticket.reload.quantity
    assert_equal "cancelled", p.reload.status
  end

  test "patch withdrawal refuses to release a remotely payable order when status is unknown" do
    p = create_participant(event: @event, user: @user, status: "awaiting_payment")
    ticket = create_ticket(event: @event, quantity: 0)
    item = TicketItem.create!(ticket: ticket, event: @event, user: @user, participant: p,
      status: "pending", amount: 100, ticket_type: "event", inventory_reserved: true,
      payment_provider: "wechat", provider_ref: "attempted")
    patch "#{@base}/#{p.id}", params: {participant: {status: "cancelled"}}, headers: auth_headers(@user)
    assert_response :unprocessable_entity
    assert_equal "awaiting_payment", p.reload.status
    assert_equal "pending", item.reload.status
    assert_equal 0, ticket.reload.quantity
  end

  test "both signup paths and approval reject unavailable events" do
    ticket = create_ticket(event: @event)
    p = create_participant(event: @event, user: @user, status: "pending")
    %w[draft pending cancelled archived closed].each do |status|
      @event.update!(status: status)
      post @base, headers: auth_headers(create_user)
      assert_response :unprocessable_entity
      post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(create_user)
      assert_response :unprocessable_entity
      post "#{@base}/#{p.id}/approve", headers: auth_headers(@owner)
      assert_response :unprocessable_entity
      assert_equal "pending", p.reload.status
    end
    @event.update!(status: "published", start_time: 2.hours.ago, end_time: 1.hour.ago)
    post @base, headers: auth_headers(create_user)
    assert_response :unprocessable_entity
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(create_user)
    assert_response :unprocessable_entity
  end

  test "reapplication resets check in and invalidates previous pass" do
    p = create_participant(event: @event, user: @user, registered_at: 1.day.ago, checked_in_at: 1.hour.ago)
    get "#{@base}/ticket_pass", headers: auth_headers(@user)
    token = json_response["token"]
    delete "#{@base}/#{p.id}", headers: auth_headers(@user)
    post @base, headers: auth_headers(@user)
    assert_response :created
    assert_nil p.reload.checked_in_at
    assert_nil p.cancelled_at
    post "#{@base}/check_in", params: {token: token}, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
  end

  test "ticket reapplication clears prior check in" do
    p = create_participant(event: @event, user: @user, status: "cancelled", checked_in_at: 1.hour.ago, cancelled_at: 1.hour.ago)
    ticket = create_ticket(event: @event)
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(@user)
    assert_response :success
    assert_nil p.reload.checked_in_at
    assert_nil p.cancelled_at
  end

  test "full venue still accepts unreserved review applications" do
    venue = create_venue(group: @group, owner: @owner, capacity: 1)
    @event.update!(venue: venue, participant_count: 1, require_approval: true)
    ticket = create_ticket(event: @event, quantity: 1)
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(@user)
    assert_response :success
    p = @event.participants.find_by!(user: @user)
    assert_equal "pending", p.status
    assert_equal 1, ticket.reload.quantity
    post "#{@base}/#{p.id}/approve", headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_equal "pending", p.reload.status
  end

  test "team pass needs no registration and rechecks current role on scan" do
    role = create_event_role(event: @event, item: @user)
    get "#{@base}/ticket_pass", headers: auth_headers(@user)
    assert_response :success
    token = json_response.fetch("token")
    assert token.present?
    assert json_response["team"]
    2.times do
      post "#{@base}/check_in", params: {token: token}, headers: auth_headers(@owner)
      assert_response :success
    end
    assert_equal 1, EventTeamCheckIn.where(event: @event, user: @user).count
    assert_equal 0, @event.reload.participant_count
    assert_not @event.participants.exists?(user: @user)
    role.destroy!
    post "#{@base}/check_in", params: {token: token}, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    get "#{@base}/ticket_pass", headers: auth_headers(@user)
    assert_response :not_found
    get "#{@base}/ticket_pass", headers: auth_headers(@owner)
    assert_response :success
    assert json_response["token"].present?
  end
end
