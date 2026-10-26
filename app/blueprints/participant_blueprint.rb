class ParticipantBlueprint < Blueprinter::Base
  identifier :id

  # registered_at = when they RSVP'd; checked_in_at = when a manager scanned
  # them at the door. Distinct — see AddCheckedInAtToParticipants.
  fields :status, :payment_status, :registered_at, :checked_in_at, :created_at
  association :user, blueprint: UserBlueprint

  # The note the applicant left. Public rosters and the embedded event list
  # stay on the default view, which omits it.
  view :with_message do
    field :message
  end
end
