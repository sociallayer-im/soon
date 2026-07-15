class MembershipBlueprint < Blueprinter::Base
  identifier :id

  fields :role, :active, :created_at
  association :user, blueprint: UserBlueprint
end
