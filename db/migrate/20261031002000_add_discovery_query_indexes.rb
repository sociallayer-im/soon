class AddDiscoveryQueryIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!
  PUBLIC_EVENT = "status = 'published' AND visibility IN ('normal','open_registration')"
  PUBLIC_TOPIC = "deleted_at IS NULL AND flagged_at IS NULL AND sync_to_community = true"
  def change
    add_index :groups, [:browse_city, :discovery_active_at, :id], order: {discovery_active_at: "DESC NULLS LAST", id: :desc}, where: "active = true AND review_status = 'approved'", name: "idx_groups_discovery_city_activity", algorithm: :concurrently
    add_index :events, [:group_id, :start_time, :id], where: PUBLIC_EVENT, name: "idx_events_discovery_group_start", algorithm: :concurrently
    add_index :events, [:start_time, :id], where: PUBLIC_EVENT, name: "idx_events_discovery_start", algorithm: :concurrently
    add_index :events, [:end_time, :start_time], where: PUBLIC_EVENT, name: "idx_events_discovery_end", algorithm: :concurrently
    add_index :events, [:owner_id, :start_time, :id], name: "idx_events_owner_start", algorithm: :concurrently
    add_index :topics, [:group_id, :created_at, :id], order: {created_at: :desc, id: :desc}, where: PUBLIC_TOPIC, name: "idx_topics_discovery_group_created", algorithm: :concurrently
    add_index :topics, [:created_at, :id], order: {created_at: :desc, id: :desc}, where: PUBLIC_TOPIC, name: "idx_topics_discovery_created", algorithm: :concurrently
    add_index :participants, [:user_id, :event_id], where: "status = 'attending' AND (payment_status IS NULL OR payment_status = 'succeeded')", name: "idx_participants_confirmed_agenda", algorithm: :concurrently
    add_index :event_roles, [:item_id, :event_id], where: "item_type = 'User'", name: "idx_event_roles_user_agenda", algorithm: :concurrently
    add_index :event_roles, [:email, :event_id], where: "item_type = 'User' AND email IS NOT NULL", name: "idx_event_roles_email_agenda", algorithm: :concurrently
    add_index :memberships, [:group_id, :user_id], name: "idx_memberships_group_user_discovery", algorithm: :concurrently
  end
end
