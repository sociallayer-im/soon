class RepairSodaIdentitySequence < ActiveRecord::Migration[8.1]
  def up
    execute "LOCK TABLE soda_identities IN SHARE ROW EXCLUSIVE MODE"
    connection.reset_pk_sequence!("soda_identities")
  end

  def down
    # Keep the sequence aligned with durable rows.
  end
end
