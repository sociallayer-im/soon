class ParticipantBlueprint < Blueprinter::Base
  identifier :id

  fields :status, :payment_status, :register_time, :created_at
  association :user, blueprint: UserBlueprint
end
