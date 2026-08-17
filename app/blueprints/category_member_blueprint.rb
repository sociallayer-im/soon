class CategoryMemberBlueprint < Blueprinter::Base
  identifier :id
  fields :created_at
  association :user, blueprint: UserBlueprint
end
