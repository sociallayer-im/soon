class TeamBlueprint < Blueprinter::Base
  identifier :id

  fields :group_id, :name, :slug, :description, :color, :sort, :members_count,
         :archived, :is_public, :created_at

  view :with_members do
    association :users, blueprint: UserBlueprint
  end
end
