class EventMailer < ApplicationMailer
  # A pending applicant was approved — they're now attending. Includes the .ics
  # so they can add the event to their calendar.
  def participant_approved(participant_id:)
    @participant = Participant.find(participant_id)
    @event = @participant.event
    recipient = @participant.user&.email
    return if recipient.blank?

    attach_invite(recipient, method: "REQUEST")
    mail(to: recipient, subject: "You're in! — #{@event.title}")
  end

  # A ticket purchase (paid or free, via TicketsController#rsvp) just succeeded —
  # confirms to the buyer, distinct from participant_approved's "your
  # application was approved" copy, which doesn't fit a direct ticket purchase.
  def ticket_purchased(participant_id:)
    @participant = Participant.find(participant_id)
    @event = @participant.event
    recipient = @participant.user&.email
    return if recipient.blank?

    attach_invite(recipient, method: "REQUEST")
    mail(to: recipient, subject: "You're confirmed — #{@event.title}")
  end

  # A pending applicant was declined.
  def participant_rejected(participant_id:)
    @participant = Participant.find(participant_id)
    @event = @participant.event
    recipient = @participant.user&.email
    return if recipient.blank?

    mail(to: recipient, subject: "Update on your application — #{@event.title}")
  end

  # An event was cancelled — the .ics carries STATUS:CANCELLED so calendars drop it.
  def cancelled(event_id:, recipient:)
    @event = Event.find(event_id)
    return if recipient.blank?

    attach_invite(recipient, method: "CANCEL")
    mail(to: recipient, subject: "Cancelled — #{@event.title}")
  end

  # An event's details changed — re-send the invite with a bumped SEQUENCE so the
  # recipient's calendar updates the entry in place (same UID).
  def updated(event_id:, recipient:)
    @event = Event.find(event_id)
    return if recipient.blank?

    attach_invite(recipient, method: "REQUEST")
    mail(to: recipient, subject: "Updated — #{@event.title}")
  end

  private

  # iTIP requires text/calendar with the METHOD as a MIME parameter for a client
  # to treat the part as an invite/update/cancel (not just a file to open).
  def attach_invite(recipient, method:)
    attachments["invite.ics"] = {
      mime_type: %(text/calendar; method=#{method}; charset=UTF-8),
      content: EventCalendar.for_event(@event, method: method, attendee: recipient)
    }
  end
end
