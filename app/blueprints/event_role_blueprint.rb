class EventRoleBlueprint < Blueprinter::Base
  identifier :id

  fields :item_id, :item_type, :role, :display_name, :image_url
  field :email, if: ->(_field, _role, options) { options[:manage_participants] == true }
end
