class AddAdminToUsers < ActiveRecord::Migration[8.1]
  # A platform-wide administrator flag. Until now the only marker was the
  # `permissions` string array containing "admin" (User#platform_admin?), which
  # is fine for a set of named capabilities but awkward for the one capability
  # that is really a yes/no property of the account — it can't be indexed
  # usefully, and "notify every admin" becomes an array containment scan.
  #
  # The column is additive: platform_admin? now answers true for either marker,
  # so existing permissions-based admins keep working and nothing has to be
  # backfilled for authorization. It is only the *notification* recipient list
  # that reads `admin` alone, and that list is new.
  def change
    add_column :users, :admin, :boolean, default: false, null: false
    add_index :users, :admin, where: "admin"
  end
end
