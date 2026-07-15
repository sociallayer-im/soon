class CommentBlueprint < Blueprinter::Base
  identifier :id

  fields :title, :item_type, :item_id, :reply_parent_id, :content, :content_type,
         :comment_type, :icon_url, :created_at

  association :user, blueprint: UserBlueprint
end
