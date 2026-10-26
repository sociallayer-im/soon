class FollowBlueprint < Blueprinter::Base
  identifier :id
  fields :user_id, :target_type, :target_id, :status, :created_at
end
