class AddNotificationKeyToActivities < ActiveRecord::Migration[8.1]
  def change
    add_column :activities, :notification_key, :string
    add_index :activities, [:receiver_id, :notification_key], unique: true, where: "notification_key IS NOT NULL", name: "index_activities_notification_dedup"
  end
end
