class PartitionOauthClients < ActiveRecord::Migration[8.1]
  def up
    add_column :oauth_applications, :provider, :string, default: "main", null: false, if_not_exists: true
    execute "UPDATE oauth_applications SET provider = 'surf' WHERE id = '3mz5yyvlmotv4'"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Keep issuer isolation during application rollback"
  end
end
