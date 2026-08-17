class CategoryBlueprint < Blueprinter::Base
  identifier :id

  fields :group_id, :name, :slug, :summary, :sort, :topics_count, :archived,
         :visibility, :created_at

  # Which teams a `visibility: "team"` board is restricted to. In the default
  # view because a team is a name, not a roster — it says "the volunteers",
  # where the old per-user list disclosed exactly who those people were.
  association :teams, blueprint: TeamRefBlueprint
end
