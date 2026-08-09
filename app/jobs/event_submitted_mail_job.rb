# Tells a group's owners and managers that someone who isn't one of them
# created an event in the group.
#
# The "is the creator an admin" test is the caller's, not this job's: by the
# time the job runs the creator may well have been promoted, and the question
# the notice answers is about the moment of creation. Who *receives* it is
# resolved here, from admin_notification, so a manager who opts out between
# enqueue and delivery is already excluded.
class EventSubmittedMailJob < ApplicationJob
  queue_as :mailers

  def perform(event_id:)
    event = Event.find(event_id)
    group = event.group
    return if group.nil?

    group.admin_notification_emails.each do |email|
      EventMailer.submitted(event_id: event.id, recipient: email).deliver_later
    end
  end
end
