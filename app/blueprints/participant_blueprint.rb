class ParticipantBlueprint < Blueprinter::Base
  identifier :id

  # registered_at = when they RSVP'd; checked_in_at = when a manager scanned
  # them at the door. Distinct — see AddCheckedInAtToParticipants.
  fields :status, :payment_status, :registered_at, :checked_in_at, :created_at
  association :user, blueprint: UserBlueprint
end
