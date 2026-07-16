class TrackBlueprint < Blueprinter::Base
  identifier :id

  fields :name, :title, :description, :image_url, :is_private, :start_date, :end_date, :created_at

  association :group, blueprint: GroupBlueprint

  view :with_roles do
    association :track_roles, blueprint: TrackRoleBlueprint
  end
end
