class ActivityBlueprint < Blueprinter::Base
  identifier :id

  fields :action, :item_type, :item_id, :has_read, :payload, :created_at

  association :initiator, blueprint: UserBlueprint
end
