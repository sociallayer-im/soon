class AddFollowReconciliation < ActiveRecord::Migration[8.1]
  def change
    # Follow reconciliation (INTEROP §10.3): our FedFollow rows and the peer's
    # follower list drift silently. last_confirmed_at records the most recent
    # proof the peer still honors the edge (an Accept); probe_count/probed_at
    # drive the re-confirmation loop.
    add_column :fed_follows, :last_confirmed_at, :datetime
    add_column :fed_follows, :probed_at, :datetime
    add_column :fed_follows, :probe_count, :integer, default: 0, null: false
  end
end
