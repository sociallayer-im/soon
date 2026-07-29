require "test_helper"

# End-to-end checks that the right email fires on each domain event. Mailer
# rendering is covered by the unit tests in test/mailers; here we only assert
# that hitting an endpoint enqueues/sends to the right recipient.
class EmailNotificationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
  end

  # ---- auth login code (deliver_now) ----

  test "request_code emails the login code to a known user" do
    user = create_user
    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      post "/api/v1/auth/request_code", params: { email: user.email }
    end
    mail = ActionMailer::Base.deliveries.last
    assert_equal [user.email], mail.to
    assert_equal "Your Social Layer sign-in code", mail.subject
  end

  test "request_code for an unknown email sends a code too — first login is signup" do
    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      post "/api/v1/auth/request_code", params: { email: "ghost@test.com" }
    end
    assert_equal ["ghost@test.com"], ActionMailer::Base.deliveries.last.to
  end

  # ---- group invite (deliver_later) ----

  test "inviting an unknown email enqueues a group invite email" do
    assert_enqueued_emails 1 do
      post "/api/v1/groups/#{@group.id}/group_invites",
        params: { receivers: ["newcomer@test.com"], role: "member" }, headers: auth_headers(@owner)
    end
    assert_response :success
  end

  # ---- participant approve / reject (deliver_later) ----

  test "approving a pending participant emails them" do
    event = create_event(group: @group, owner: @owner, require_approval: true)
    attendee = create_user
    participant = create_participant(event: event, user: attendee, status: "pending")

    perform_enqueued_jobs do
      post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(@owner)
    end
    assert_response :success
    mail = ActionMailer::Base.deliveries.last
    assert_equal [attendee.email], mail.to
    assert_match "You're in!", mail.subject
  end

  test "rejecting a pending participant emails them and sets status declined" do
    event = create_event(group: @group, owner: @owner, require_approval: true)
    attendee = create_user
    participant = create_participant(event: event, user: attendee, status: "pending")

    perform_enqueued_jobs do
      post "/api/v1/events/#{event.id}/participants/#{participant.id}/reject", headers: auth_headers(@owner)
    end
    assert_response :success
    assert_equal "declined", participant.reload.status
    assert_match "Update on your application", ActionMailer::Base.deliveries.last.subject
  end

  # ---- event cancellation (deliver_later, fan-out to attendees) ----

  test "cancelling an event emails every attending participant" do
    event = create_event(group: @group, owner: @owner)
    a1 = create_user
    a2 = create_user
    create_participant(event: event, user: a1, status: "attending")
    create_participant(event: event, user: a2, status: "attending")
    create_participant(event: event, user: create_user, status: "declined") # not notified

    assert_enqueued_emails 2 do
      delete "/api/v1/events/#{event.id}", headers: auth_headers(@owner)
    end
    assert_response :no_content
  end

  # ---- feedback comment (deliver_later, only for feedback type) ----

  test "a feedback comment on an event emails the event owner" do
    event = create_event(group: @group, owner: @owner)
    author = create_user

    assert_enqueued_emails 1 do
      post "/api/v1/comments",
        params: { comment: { item_type: "Event", item_id: event.id, content: "great!", comment_type: "feedback" } },
        headers: auth_headers(author)
    end
    assert_response :created
  end

  test "a non-feedback comment does not email anyone" do
    event = create_event(group: @group, owner: @owner)
    author = create_user

    assert_no_enqueued_emails do
      post "/api/v1/comments",
        params: { comment: { item_type: "Event", item_id: event.id, content: "hi", comment_type: "comment" } },
        headers: auth_headers(author)
    end
    assert_response :created
  end

  # ---- group ticket purchase (deliver_later) ----

  test "buying a group ticket notifies the group owner and confirms the buyer" do
    event = create_event(group: @group, owner: @owner)
    event.update_column(:kind, "group_ticket")
    ticket = create_ticket(event: event) # free -> succeeds immediately, ticket_type group
    buyer = create_user

    assert_enqueued_emails 2 do
      post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    end
    assert_response :success

    # Both mailers happen to share the method name "ticket_purchased" — assert
    # on the (mailer class, action) pair so this doesn't silently pass if one
    # of the two stops firing.
    mailer_calls = enqueued_jobs.select { |j| j[:job] == ActionMailer::MailDeliveryJob }.map { |j| j[:args][0..1] }
    assert_includes mailer_calls, ["EventMailer", "ticket_purchased"], "expected the buyer confirmation email"
    assert_includes mailer_calls, ["GroupMailer", "ticket_purchased"], "expected the group owner notification email"
  end
end
