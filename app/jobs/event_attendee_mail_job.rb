# Mails every attending participant of an event — used when the event is
# cancelled or its calendar-visible details change, so attendees' calendars get
# the .ics update.
#
# Same reasoning as GroupBroadcastMailJob: the scan over participants used to
# happen inline in the request that cancelled/updated the event. Here it costs
# the caller one enqueue, and each attendee's mail retries independently.
class EventAttendeeMailJob < ApplicationJob
  queue_as :mailers

  # Only the EventMailer actions that take (event_id:, recipient:) and address
  # the whole attendee list. Allowlisted rather than trusted, since the action
  # name reaches public_send.
  ACTIONS = %w[cancelled updated].freeze

  def perform(event_id:, mailer_action:)
    action = mailer_action.to_s
    raise ArgumentError, "unsupported EventMailer action: #{action}" unless ACTIONS.include?(action)

    event = Event.find(event_id)

    event.participants.where(status: "attending").includes(:user).find_each do |participant|
      email = participant.user&.email
      next if email.blank?

      EventMailer.public_send(action, event_id: event.id, recipient: email).deliver_later
    end
  end
end
