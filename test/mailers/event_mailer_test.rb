require "test_helper"

class EventMailerTest < ActionMailer::TestCase
  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner, title: "Launch Party")
    @attendee = create_user
  end

  test "participant_approved emails the attendee and attaches a REQUEST invite in the event zone" do
    @event.update!(timezone: "Asia/Shanghai",
      start_time: Time.utc(2026, 7, 16, 6, 0, 0), end_time: Time.utc(2026, 7, 16, 8, 0, 0))
    participant = create_participant(event: @event, user: @attendee, status: "attending")
    mail = EventMailer.participant_approved(participant_id: participant.id)

    assert_equal [@attendee.email], mail.to
    assert_equal "You're in! — Launch Party", mail.subject
    ics = mail.attachments["invite.ics"]
    assert ics.present?, "should attach invite.ics"
    assert_match "SUMMARY:Launch Party", ics.body.to_s
    assert_match "STATUS:CONFIRMED", ics.body.to_s
    # The invite carries the event's own zone (14:00 Shanghai == 06:00 UTC), NOT a
    # floating time — so any recipient's calendar shows the correct instant.
    assert_match "DTSTART;TZID=Asia/Shanghai:20260716T140000", ics.body.to_s
    assert_match "BEGIN:VTIMEZONE", ics.body.to_s
    # iTIP method belongs on the MIME part so clients treat it as an invitation.
    assert_match(/method=REQUEST/i, ics.content_type)
    # The email copy shows the event-local time, not UTC.
    assert_match "14:00", mail.html_part.body.to_s
  end

  test "participant_rejected emails the attendee without an attachment" do
    participant = create_participant(event: @event, user: @attendee, status: "declined")
    mail = EventMailer.participant_rejected(participant_id: participant.id)

    assert_equal [@attendee.email], mail.to
    assert_equal "Update on your application — Launch Party", mail.subject
    assert_empty mail.attachments
  end

  test "cancelled emails the recipient with a CANCELLED calendar update" do
    mail = EventMailer.cancelled(event_id: @event.id, recipient: @attendee.email)

    assert_equal [@attendee.email], mail.to
    assert_equal "Cancelled — Launch Party", mail.subject
    ics = mail.attachments["invite.ics"]
    assert ics.present?
    assert_match "STATUS:CANCELLED", ics.body.to_s
    assert_match "METHOD:CANCEL", ics.body.to_s
  end

  test "submitted names the creator, the event and the group, and carries no invite" do
    creator = create_user(name: "member-user")
    @event.update!(owner: creator, status: "published")

    mail = EventMailer.submitted(event_id: @event.id, recipient: @owner.email)

    assert_equal [@owner.email], mail.to
    assert_equal "New event — Launch Party", mail.subject
    assert_match "member-user", mail.html_part.body.to_s
    assert_match @group.display_name, mail.html_part.body.to_s
    # The recipient is being asked to look at the event, not to attend it — an
    # .ics here would put someone else's event on a reviewer's calendar.
    assert_empty mail.attachments
  end

  test "submitted says review is needed when the event is pending" do
    @event.update!(status: "pending")

    mail = EventMailer.submitted(event_id: @event.id, recipient: @owner.email)

    assert_equal "Review needed — Launch Party", mail.subject
    assert_match "waiting for review", mail.html_part.body.to_s
  end
end
