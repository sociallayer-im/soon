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

    # The request only enqueues the fan-out job; the per-attendee mail is
    # enqueued when that job runs, so run it (and only it) inline.
    assert_enqueued_emails 2 do
      perform_enqueued_jobs(only: EventAttendeeMailJob) do
        delete "/api/v1/events/#{event.id}", headers: auth_headers(@owner)
      end
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
    event = create_group_ticket_event(group: @group, owner: @owner)
    ticket = create_ticket(event: event) # free -> succeeds immediately, ticket_type group
    buyer = create_user

    assert_enqueued_emails 2 do
      post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    end
    assert_response :success

    # Both mailers happen to share the method name "ticket_purchased" — assert
    # on the (mailer class, action) pair so this doesn't silently pass if one
    # of the two stops firing.
    mailer_calls = enqueued_jobs.select { |j| j[:job] == MailDeliveryJob }.map { |j| j[:args][0..1] }
    assert_includes mailer_calls, ["EventMailer", "ticket_purchased"], "expected the buyer confirmation email"
    assert_includes mailer_calls, ["GroupMailer", "ticket_purchased"], "expected the group owner notification email"
  end

  # ---- new group registered -> platform admins ----

  test "creating a group emails every platform admin" do
    admin = create_user(admin: true, email: "admin@test.com")
    create_user(admin: true, email: nil, eth: "0x#{unique_suffix}") # no address to write to
    create_user(admin: false) # not an admin

    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      perform_enqueued_jobs do
        post "/api/v1/groups", params: { group: { name: "brand-new-#{unique_suffix}" } },
          headers: auth_headers(create_user)
      end
    end
    assert_response :created

    mail = ActionMailer::Base.deliveries.last
    assert_equal [admin.email], mail.to
    assert_match "New group", mail.subject
  end

  test "creating a group sends nothing when there is no platform admin" do
    assert_no_enqueued_jobs only: MailDeliveryJob do
      perform_enqueued_jobs only: GroupRegisteredMailJob do
        post "/api/v1/groups", params: { group: { name: "quiet-#{unique_suffix}" } },
          headers: auth_headers(create_user)
      end
    end
    assert_response :created
  end

  # ---- new event by a non-admin -> subscribed group admins ----

  test "an event created by a plain member emails the group's owner and managers" do
    manager = create_user(email: "manager@test.com")
    create_membership(user: manager, group: @group, role: "manager")
    member = create_user
    create_membership(user: member, group: @group, role: "member")

    # owner + manager, both opted in by default
    assert_difference -> { ActionMailer::Base.deliveries.size }, 2 do
      perform_enqueued_jobs do
        post "/api/v1/events", params: { event: event_attrs }, headers: auth_headers(member)
      end
    end
    assert_response :created

    assert_equal [[@owner.email], [manager.email]].flatten.sort,
      ActionMailer::Base.deliveries.flat_map(&:to).sort
  end

  test "an admin who opted out of admin_notification is not mailed" do
    manager = create_user(email: "optedout@test.com")
    create_membership(user: manager, group: @group, role: "manager", admin_notification: false)
    member = create_user
    create_membership(user: member, group: @group, role: "member")

    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do # the owner only
      perform_enqueued_jobs do
        post "/api/v1/events", params: { event: event_attrs }, headers: auth_headers(member)
      end
    end
    assert_equal [@owner.email], ActionMailer::Base.deliveries.flat_map(&:to)
  end

  test "an event created by a group manager notifies nobody" do
    manager = create_user
    create_membership(user: manager, group: @group, role: "manager")

    assert_no_enqueued_jobs only: [GroupRegisteredMailJob, EventSubmittedMailJob] do
      post "/api/v1/events", params: { event: event_attrs }, headers: auth_headers(manager)
    end
    assert_response :created
  end

  test "a draft event does not notify — nobody can see it yet" do
    member = create_user
    create_membership(user: member, group: @group, role: "member")

    assert_no_enqueued_jobs only: EventSubmittedMailJob do
      post "/api/v1/events", params: { event: event_attrs.merge(status: "draft") },
        headers: auth_headers(member)
    end
    assert_response :created
  end

  test "an event awaiting review notifies, and says so" do
    member = create_user
    create_membership(user: member, group: @group, role: "member")

    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      perform_enqueued_jobs do
        post "/api/v1/events", params: { event: event_attrs.merge(status: "pending") },
          headers: auth_headers(member)
      end
    end
    assert_match "Review needed", ActionMailer::Base.deliveries.last.subject
  end

  private

  # status is sent explicitly because the editor sends it (seastar-app's
  # event/[grouphandle]/create/data.ts posts "published"); the column's own
  # default is "draft", which is the one case that deliberately notifies nobody.
  def event_attrs
    { title: "Submitted #{unique_suffix}", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour,
      group_id: @group.id, status: "published" }
  end
end
