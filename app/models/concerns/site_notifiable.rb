# Only writes database rows: notifications commit/rollback with the business change.
module SiteNotifiable
  extend ActiveSupport::Concern
  included do
    attr_accessor :skip_site_notification
    after_save :record_site_notification
  end
  private
  def record_site_notification
    return if skip_site_notification
    SiteNotifications.record(self, saved_changes, actor: NotificationContext.actor)
  end
end
