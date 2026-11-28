class AddDiscoveryContributionIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!
  def change
    add_index :events, [:group_id, :created_at, :id], order: {created_at: :desc, id: :desc},
      where: "status = 'published' AND visibility IN ('normal','open_registration')",
      name: "idx_events_discovery_contribution", algorithm: :concurrently
  end
end
