class HardenFederationInvariants < ActiveRecord::Migration[8.1]
  def up
    # The instance keypair is a singleton, but nothing at the DB level said
    # so — FedInstanceKey.create_singleton rescued RecordNotUnique with no
    # unique index to raise it, so a concurrent first boot could mint two
    # keys and answer key fetches inconsistently. A constant guard column
    # with a unique index makes the race lose deterministically.
    execute <<~SQL
      DELETE FROM fed_instance_keys
      WHERE id NOT IN (SELECT id FROM fed_instance_keys ORDER BY created_at ASC LIMIT 1)
    SQL
    add_column :fed_instance_keys, :singleton_guard, :integer, null: false, default: 0
    add_index :fed_instance_keys, :singleton_guard, unique: true

    # Inbound ledger rows now start as "received" and are moved to their
    # terminal state by InboundJob (FedInboundActivity lifecycle).
    change_column_default :fed_inbound_activities, :status, from: "processed", to: "received"
  end

  def down
    change_column_default :fed_inbound_activities, :status, from: "received", to: "processed"
    remove_index :fed_instance_keys, :singleton_guard
    remove_column :fed_instance_keys, :singleton_guard
  end
end
