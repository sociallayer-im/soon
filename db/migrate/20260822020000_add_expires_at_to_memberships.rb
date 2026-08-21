class AddExpiresAtToMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :memberships, :expires_at, :datetime
    add_index :memberships, :expires_at
  end
end
