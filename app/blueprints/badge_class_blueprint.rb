class BadgeClassBlueprint < Blueprinter::Base
  identifier :id

  fields :name, :title, :metadata, :content, :image_url, :group_id, :counter,
         :transferable, :revocable, :weighted, :encrypted, :badge_type, :permissions,
         :display, :can_send_badge, :created_at

  association :creator, blueprint: UserBlueprint
end
