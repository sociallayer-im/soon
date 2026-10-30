require "test_helper"
class Api::V1::EventTicketPassTest < ActionDispatch::IntegrationTest
  setup do
    @owner = create_user
    @attendee = create_user
    group = create_group(owner: @owner)
    @event = create_event(group: group, owner: @owner)
    @participant = create_participant(event: @event, user: @attendee, status: "attending", registered_at: Time.current)
    @base = "/api/v1/events/#{@event.id}/participants"
  end
  test "holder credential requires manager and repeat scan preserves timestamp" do
    get "#{@base}/ticket_pass", headers: auth_headers(@attendee)
    assert_response :success
    token = response.parsed_body.fetch("token")
    assert token.present?
    post "#{@base}/check_in", params: { token: token }, headers: auth_headers(@attendee)
    assert_response :forbidden
    post "#{@base}/check_in", params: { token: token }, headers: auth_headers(@owner)
    assert_response :success
    stamp = @participant.reload.checked_in_at
    assert stamp
    post "#{@base}/check_in", params: { token: token }, headers: auth_headers(@owner)
    assert_response :success
    assert_equal stamp, @participant.reload.checked_in_at
  end
  test "pending cancelled forged and expired credentials fail" do
    get "#{@base}/ticket_pass", headers: auth_headers(@attendee)
    token = response.parsed_body.fetch("token")
    post "#{@base}/check_in", params: { token: token + "x" }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    travel 16.minutes do
      post "#{@base}/check_in", params: { token: token }, headers: auth_headers(@owner)
      assert_response :unprocessable_entity
    end
    @participant.update!(status: "pending")
    get "#{@base}/ticket_pass", headers: auth_headers(@attendee)
    assert_nil response.parsed_body["token"]
    post "#{@base}/check_in", params: { user_id: @attendee.id }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    @participant.update!(status: "cancelled")
    post "#{@base}/check_in", params: { token: token }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_nil @participant.reload.checked_in_at
    get "#{@base}/ticket_pass", headers: auth_headers(create_user)
    assert_response :not_found
  end
  test "unpaid and refunded orders block admission and codes cannot cross events" do
    ticket = create_ticket(event: @event)
    item = TicketItem.create!(ticket: ticket, event: @event, user: @attendee, participant: @participant,
                             status: "pending", amount: 100, ticket_type: "event")
    get "#{@base}/ticket_pass", headers: auth_headers(@attendee)
    assert_response :success
    assert_nil response.parsed_body["token"]
    post "#{@base}/check_in", params: { user_id: @attendee.id }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    item.update!(status: "succeeded")
    get "#{@base}/ticket_pass", headers: auth_headers(@attendee)
    token = response.parsed_body.fetch("token")
    other = create_event(group: @event.group, owner: @owner)
    post "/api/v1/events/#{other.id}/participants/check_in", params: { token: token }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    item.update!(status: "refunded")
    post "#{@base}/check_in", params: { token: token }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_nil @participant.reload.checked_in_at
  end

end
