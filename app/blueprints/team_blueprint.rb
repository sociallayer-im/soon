class TeamBlueprint < Blueprinter::Base
  identifier :id

  fields :group_id, :name, :slug, :description, :color, :sort, :members_count,
         :archived, :created_at

  view :with_members do
    association :users, blueprint: UserBlueprint
  end
end
