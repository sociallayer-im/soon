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
    # Deliberately not ReplyPolicy.new(...).update? per reply: that resolves
    # the group and asks the memberships table again for every floor, which is
    # one query per row. The manager half of the answer is the same for the
    # whole thread, so the controller resolves it once and passes it in; only
    # the authorship half varies.
    field :can_edit do |reply, options|
      options[:can_manage] || reply.user_id == options[:current_user]&.id
    end
  end
end
