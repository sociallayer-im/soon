class TopicBlueprint < Blueprinter::Base
  identifier :id

  # Lists keep bounded text; attachments are returned independently.
  fields :event_id, :sync_to_community, :group_id, :category_id, :title, :image_url, :tags,
         :replies_count, :stars_count, :replied_at, :created_at, :updated_at

  field(:excerpt) { |topic| topic.list_media[:text].first(600) }
  field(:image_urls) { |topic| topic.list_media[:images] }
  # Compatibility for older clients which extract trailing attachment Markdown.
  field :content do |topic|
    media = topic.list_media
    ([media[:text].first(600)] + media[:images].reject { |url| url == topic.image_url }.map { |url| "![Surf 帖子附件](#{url})" }).join("\n\n")
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
