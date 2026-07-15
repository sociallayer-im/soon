class ParticipantBlueprint < Blueprinter::Base
  identifier :id

  fields :status, :payment_status, :created_at
  association :user, blueprint: UserBlueprint
end
