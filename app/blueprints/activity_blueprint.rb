class ActivityBlueprint < Blueprinter::Base
  identifier :id

  fields :action, :item_type, :item_id, :has_read, :payload, :created_at

  field :target do |notice, options|
    SiteNotifications.target(notice, options[:viewer]) if options[:viewer]
  end
  field :title do |notice|
    notice.payload.to_h["title"] if notice.action.start_with?("surf/")
  end
  field :content do |notice|
    notice.payload.to_h["body"] if notice.action.start_with?("surf/")
  end

  association :initiator, blueprint: UserBlueprint
end
