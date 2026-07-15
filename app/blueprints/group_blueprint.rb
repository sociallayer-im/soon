class GroupBlueprint < Blueprinter::Base
  identifier :id

  fields :name, :created_at

  view :extended do
    association :members, blueprint: UserBlueprint, name: :users
  end
end
