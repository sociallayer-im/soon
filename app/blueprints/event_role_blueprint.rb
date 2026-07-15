class EventRoleBlueprint < Blueprinter::Base
  identifier :id

  fields :item_id, :item_type, :role, :email, :display_name, :image_url
end
