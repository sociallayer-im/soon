class CreateFedDomainTables < ActiveRecord::Migration[8.1]
  # Domain governance + observability (design/FEDERATION_PLAN.md §2.9/§2.10).
  # Ships in the same phase that opens the inbox — the inbox is never exposed
  # without blocklist and counters.
  def change
    create_table :fed_domain_policies, id: :string do |t|
      t.string :domain, null: false, index: {unique: true}
      t.string :policy, null: false # blocked | allowed
      t.string :reason
      t.string :created_by
      t.timestamps
    end

    create_table :fed_domain_stats, id: :string do |t|
      t.string :domain, null: false, index: {unique: true}
      t.integer :delivered_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.integer :inbound_count, null: false, default: 0
      t.integer :inbound_rejected_count, null: false, default: 0
      t.datetime :last_success_at
      t.datetime :last_failure_at
      t.date :unavailable_since
      t.string :last_error
      t.timestamps
    end
  end
end
