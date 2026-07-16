class BadgeBlueprint < Blueprinter::Base
  identifier :id

  fields :index, :title, :image_url, :content, :status, :display,
         :value, :start_time, :end_time, :created_at

  association :badge_class, blueprint: BadgeClassBlueprint
  association :creator, blueprint: UserBlueprint
  association :owner, blueprint: UserBlueprint
end
