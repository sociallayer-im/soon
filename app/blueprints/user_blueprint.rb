class UserBlueprint < Blueprinter::Base
  identifier :id

  fields :name, :email, :created_at

  view :extended do
    association :groups, blueprint: GroupBlueprint
  end
end
