class SiteNotificationReminderJob < ApplicationJob
  retry_on ActiveRecord::ConnectionNotEstablished, wait: 30.seconds, attempts: 3

  # Re-read current dates, status, roles and settled registrations at execution.
  # Deduplication is database-enforced across cron processes and retries.
  def perform
    Event.where(status: "published", start_time: Time.current..2.hours.from_now).find_each do |event|
      ids = event.participants.where(status: "attending", payment_status: [nil, "succeeded"]).pluck(:user_id)
      ids << event.owner_id
      ids.concat(SiteNotifications.role_links(event).keys)
      User.where(id: ids.uniq).find_each do |user|
        SiteNotifications.emit(receiver: user, item: event, action: "event_reminder", title: "活动即将开始",
          body: "「#{event.title}」将在 #{event.start_time.in_time_zone(event.event_timezone).strftime('%m月%d日 %H:%M')} 开始，请查看地点和入场说明。",
          key: "reminder:#{event.id}:#{event.start_time.iso8601(6)}")
      end
    end
  end
end
