class TopicBlueprint < Blueprinter::Base
  identifier :id

  # Preserve Markdown attachments, including images after the text preview.
  fields :content, :event_id, :sync_to_community, :group_id, :category_id, :title, :image_url, :tags,
         :replies_count, :stars_count, :replied_at, :created_at, :updated_at

  # A bounded list preview avoids one full-body fetch per feed card.
  field :excerpt do |topic|
    topic.content.to_s.first(600)
  end

  field :pinned do |topic|
    topic.pinned?
  end

  field :closed do |topic|
    topic.closed?
  end

  field :flagged do |topic|
    topic.flagged?
  end

  # Reaches only the author and managers — nobody else is served a flagged
  # topic at all.
  field :flag_reason

  field :is_starred do |topic, options|
    options[:starred_ids] ? options[:starred_ids].include?(topic.id) : false
  end

  association :user, blueprint: UserBlueprint
  association :last_reply_user, blueprint: UserBlueprint
  association :category, blueprint: CategoryRefBlueprint

  view :detail do
    fields :content, :content_type

    field :can_edit do |topic, options|
      TopicPolicy.new(options[:current_user], topic).update?
    end

    field :can_manage do |topic, options|
      TopicPolicy.new(options[:current_user], topic).flag?
    end
  end
end
