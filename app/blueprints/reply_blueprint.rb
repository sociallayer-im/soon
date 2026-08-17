class ReplyBlueprint < Blueprinter::Base
  identifier :id

  fields :topic_id, :content, :content_type, :reply_to_id, :created_at, :updated_at

  field :flagged do |reply|
    reply.flagged?
  end

  # Only its author and a manager ever receive this — a flagged reply is not
  # rendered at all for anyone else, and the reason is what makes the hiding
  # explainable rather than arbitrary.
  field :flag_reason

  association :user, blueprint: UserBlueprint
  association :reply_to, blueprint: ReplyRefBlueprint

  view :with_permissions do
    field :can_edit do |reply, options|
      ReplyPolicy.new(options[:current_user], reply).update?
    end
  end
end
