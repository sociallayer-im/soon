class MarkerBlueprint < Blueprinter::Base
  identifier :id

  fields :category, :pin_image_url, :cover_image_url, :title, :about,
         :link, :status, :data, :created_at

  association :place, blueprint: PlaceBlueprint
  association :group, blueprint: GroupBlueprint
  association :owner, blueprint: UserBlueprint
end
