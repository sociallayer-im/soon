require "test_helper"

# The two fan-out jobs and the shared mail delivery job. The endpoints that
# enqueue these are covered in test/integration/email_notifications_test.rb;
# here we exercise the jobs directly — who they pick as recipients, and what
# they do when the world changed between enqueue and execution.
class MailJobsTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  # ---- MailDeliveryJob ----

  test "deliver_later routes through MailDeliveryJob, not ActionMailer's default" do
    assert_equal MailDeliveryJob, ActionMailer::Base.delivery_job
    assert MailDeliveryJob < ActionMailer::MailDeliveryJob,
      "must subclass ActionMailer::MailDeliveryJob or assert_enqueued_emails stops matching it"
    assert_equal "mailers", MailDeliveryJob.new.queue_name
  end

  test "a mail job whose subject was deleted is discarded, not retried forever" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    mail = EventMailer.cancelled(event_id: event.id, recipient: "someone@test.com")
    event.destroy!

    # The mailer calls Event.find in the job, so this raises RecordNotFound —
    # discard_on must swallow it rather than let it bubble and re-run.
    assert_nothing_raised do
      perform_enqueued_jobs { mail.deliver_later }
    end
    assert_empty ActionMailer::Base.deliveries
  end

  # ---- EventAttendeeMailJob ----

  test "mails only attending participants who have an email" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    create_participant(event: event, user: create_user(email: "a@test.com"), status: "attending")
    create_participant(event: event, user: create_user(email: "b@test.com"), status: "attending")
    create_participant(event: event, user: create_user(email: "c@test.com"), status: "declined")
    create_participant(event: event, user: create_user(email: nil, eth: "0x#{unique_suffix}"), status: "attending")

    assert_enqueued_emails 2 do
      EventAttendeeMailJob.perform_now(event_id: event.id, mailer_action: "cancelled")
    end
  end

  test "the mailer action is allowlisted — an arbitrary method name cannot reach public_send" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    create_participant(event: event, user: create_user(email: "a@test.com"), status: "attending")

    assert_raises(ArgumentError) do
      EventAttendeeMailJob.perform_now(event_id: event.id, mailer_action: "participant_approved")
    end
    assert_no_enqueued_jobs only: MailDeliveryJob
  end

  test "an event deleted before the fan-out runs is discarded" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    event_id = event.id
    event.destroy!

    assert_nothing_raised do
      perform_enqueued_jobs(only: EventAttendeeMailJob) do
        EventAttendeeMailJob.perform_later(event_id: event_id, mailer_action: "cancelled")
      end
    end
  end

  # ---- GroupBroadcastMailJob / Group#member_emails ----

  test "broadcasts to each active member once, skipping inactive and email-less members" do
    owner = create_user(email: "owner@test.com")
    group = create_group(owner: owner)
    create_membership(user: create_user(email: "m1@test.com"), group: group)
    create_membership(user: create_user(email: nil, eth: "0x#{unique_suffix}"), group: group)
    inactive = create_membership(user: create_user(email: "gone@test.com"), group: group)
    inactive.update!(active: false)

    assert_enqueued_emails 2 do
      GroupBroadcastMailJob.perform_now(group_id: group.id, subject: "Hi", content: "News")
    end
  end

  test "member_emails is what send_email reports as sent_count — the two must not drift" do
    owner = create_user(email: "owner@test.com")
    group = create_group(owner: owner)
    create_membership(user: create_user(email: "m1@test.com"), group: group)
    create_membership(user: create_user(email: nil, eth: "0x#{unique_suffix}"), group: group)

    assert_equal %w[m1@test.com owner@test.com], group.member_emails.sort
    assert_enqueued_emails group.member_emails.size do
      GroupBroadcastMailJob.perform_now(group_id: group.id, subject: "Hi", content: "News")
    end
  end

  # ---- GroupRegisteredMailJob ----

  test "mails platform admins who have an address, and nobody else" do
    create_user(admin: true, email: "a1@test.com")
    create_user(admin: true, email: "a2@test.com")
    create_user(admin: true, email: nil, eth: "0x#{unique_suffix}")
    create_user(email: "ordinary@test.com")
    group = create_group(owner: create_user)

    assert_enqueued_emails 2 do
      GroupRegisteredMailJob.perform_now(group_id: group.id)
    end
  end

  # platform_admin? also answers to the legacy permissions array, but the
  # notification list deliberately does not — being able to remove a popup city
  # is not a request for mail about every group that signs up.
  test "a permissions-array admin is authorized but is not a mail recipient" do
    legacy = create_user(permissions: ["admin"], email: "legacy@test.com")
    group = create_group(owner: create_user)

    assert legacy.platform_admin?
    assert_no_enqueued_emails do
      GroupRegisteredMailJob.perform_now(group_id: group.id)
    end
  end

  # ---- EventSubmittedMailJob ----

  test "mails the group's owners and managers who are still subscribed" do
    owner = create_user(email: "owner@test.com")
    group = create_group(owner: owner)
    create_membership(user: create_user(email: "mgr@test.com"), group: group, role: "manager")
    create_membership(user: create_user(email: "muted@test.com"), group: group, role: "manager",
      admin_notification: false)
    create_membership(user: create_user(email: "member@test.com"), group: group, role: "member")
    create_membership(user: create_user(email: nil, eth: "0x#{unique_suffix}"), group: group, role: "manager")
    event = create_event(group: group, owner: create_user)

    assert_enqueued_emails 2 do # owner + the one subscribed manager with an address
      EventSubmittedMailJob.perform_now(event_id: event.id)
    end
  end

  test "existing owner and manager rows default to subscribed" do
    owner = create_user(email: "owner@test.com")
    group = create_group(owner: owner)
    manager = create_membership(user: create_user(email: "mgr@test.com"), group: group, role: "manager")

    assert manager.admin_notification, "a new manager must be opted in by default"
    assert_equal %w[mgr@test.com owner@test.com], group.admin_notification_emails.sort
  end

  test "an inactive admin membership is not mailed" do
    owner = create_user(email: "owner@test.com")
    group = create_group(owner: owner)
    group.memberships.find_by(user: owner).update!(active: false)
    event = create_event(group: group, owner: create_user)

    assert_no_enqueued_emails do
      EventSubmittedMailJob.perform_now(event_id: event.id)
    end
  end
end
