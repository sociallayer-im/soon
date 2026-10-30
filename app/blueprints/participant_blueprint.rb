class ParticipantBlueprint < Blueprinter::Base
  identifier :id

  # registered_at = when they RSVP'd; checked_in_at = when a manager scanned
  # them at the door. Distinct — see AddCheckedInAtToParticipants.
  fields :status, :payment_status, :registered_at, :checked_in_at, :created_at
  %i[reviewed_at review_reason payment_due_at cancellation_reason message].each do |name|
    field name, if: ->(_n, participant, options) { options[:manager] || options[:own] || options[:viewer_id] == participant.user_id }
  end
  field :reviewed_by_id, if: ->(_n, _participant, options) { options[:manager] || options[:own] }
  field :application_answers, if: ->(_n, _p, options) { options[:manager] } do |participant, _options|
    _options.fetch(:application_answers, {}).fetch(participant.user_id, [])
  end
  field :review_tickets, if: ->(_n, _p, options) { options[:manager] } do |participant, options|
    options.fetch(:review_tickets, {}).fetch(participant.id, [])
  end
  association :user, blueprint: UserBlueprint
end
