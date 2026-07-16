class EventMailer < ApplicationMailer
  # A pending applicant was approved — they're now attending. Includes the .ics
  # so they can add the event to their calendar.
  def participant_approved(participant_id:)
    @participant = Participant.find(participant_id)
    @event = @participant.event
    recipient = @participant.user&.email
    return if recipient.blank?

    attachments["invite.ics"] = { mime_type: "text/calendar", content: @event.to_ics }
    mail(to: recipient, subject: "You're in! — #{@event.title}")
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

    attachments["invite.ics"] = { mime_type: "text/calendar", content: @event.to_ics(cancelled: true) }
    mail(to: recipient, subject: "Cancelled — #{@event.title}")
  end
end
