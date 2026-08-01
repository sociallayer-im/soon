class AddFederationKeysToUsersAndGroups < ActiveRecord::Migration[8.1]
  # RSA keypair per federation actor (design/FEDERATION_PLAN.md §2.5).
  # Lazily generated on first webfinger/follow, so NULL is the normal state —
  # no backfill. Private key is AR-encrypted at the model layer
  # (FederationKeyable), which is why the column is text, not a key type.
  def change
    add_column :users, :fed_private_key, :text
    add_column :users, :fed_public_key, :text
    add_column :groups, :fed_private_key, :text
    add_column :groups, :fed_public_key, :text
  end
end
