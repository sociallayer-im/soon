class AddTicketOwnerNotificationMarker < ActiveRecord::Migration[8.1]
  def up
    add_column :ticket_items, :group_owner_notified_at, :datetime
    # Old settled group purchases already passed through the legacy notifier.
    execute <<~SQL
      UPDATE ticket_items SET group_owner_notified_at = COALESCE(paid_at, updated_at)
      WHERE ticket_type = 'group' AND status = 'succeeded'
    SQL
  end

  def down
    remove_column :ticket_items, :group_owner_notified_at
  end
end
