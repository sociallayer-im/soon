class ReplyBlueprint < Blueprinter::Base
  identifier :id

  fields :topic_id, :content, :content_type, :reply_to_id, :stars_count,
         :created_at, :updated_at

  # Resolved for the whole page in one query and handed in, rather than asking
  # per reply — a 50-floor thread would otherwise be 50 extra round trips.
  field :is_starred do |reply, options|
    options[:starred_reply_ids] ? options[:starred_reply_ids].include?(reply.id) : false
  end

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
