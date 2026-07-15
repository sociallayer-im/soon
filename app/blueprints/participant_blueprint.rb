class ParticipantBlueprint < Blueprinter::Base
  identifier :id

  fields :status, :created_at
  association :user, blueprint: UserBlueprint
end
