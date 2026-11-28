class IndexNotificationTaskQueries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!
  def change
    add_index :activities, [:receiver_id, :created_at, :id], name: "idx_activities_receiver_timeline", algorithm: :concurrently, if_not_exists: true
    add_index :activities, :receiver_id, where: "has_read = false", name: "idx_activities_receiver_unread", algorithm: :concurrently, if_not_exists: true
    add_index :withdrawals, [:status, :created_at, :id], name: "idx_withdrawals_pending_tasks", algorithm: :concurrently, if_not_exists: true
    add_index :group_invites, [:group_id, :status, :created_at, :id], name: "idx_group_invites_review_tasks", algorithm: :concurrently, if_not_exists: true
  end
end
