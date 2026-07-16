require "test_helper"

class EventMailerTest < ActionMailer::TestCase
  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner, title: "Launch Party")
    @attendee = create_user
  end

  test "participant_approved emails the attendee and attaches a calendar invite" do
    participant = create_participant(event: @event, user: @attendee, status: "attending")
    mail = EventMailer.participant_approved(participant_id: participant.id)

    assert_equal [@attendee.email], mail.to
    assert_equal "You're in! — Launch Party", mail.subject
    ics = mail.attachments["invite.ics"]
    assert ics.present?, "should attach invite.ics"
    assert_match "BEGIN:VCALENDAR", ics.body.to_s
    assert_match "SUMMARY:Launch Party", ics.body.to_s
    assert_match "STATUS:CONFIRMED", ics.body.to_s
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
end
