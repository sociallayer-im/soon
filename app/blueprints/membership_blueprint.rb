class MembershipBlueprint < Blueprinter::Base
  identifier :id

  fields :role, :active, :created_at
  association :user, blueprint: UserBlueprint

  # For "which groups does this user belong to" listings.
  view :with_group do
    association :group, blueprint: GroupBlueprint
  end
end
