class AddMoveIntegrityAndCustomDomain < ActiveRecord::Migration[8.1]
  def change
    # Move semantics (FEDERATION_PLAN §9.6): movedTo on the departing side,
    # alsoKnownAs on the claiming side. Both directions need both fields.
    add_column :users, :fed_moved_to, :string
    add_column :users, :fed_also_known_as, :jsonb, default: [], null: false
    add_column :groups, :fed_moved_to, :string
    add_column :groups, :fed_also_known_as, :jsonb, default: [], null: false
    add_column :fed_actors, :moved_to, :string
    add_column :fed_actors, :also_known_as, :jsonb, default: [], null: false

    # FEP-8b32 object integrity proofs: a second, Ed25519 keypair per actor
    # (the RSA one stays for HTTP signatures). Private key encrypted like
    # fed_private_key; public stored as a Multikey multibase string.
    add_column :users, :fed_ed25519_private_key, :text
    add_column :users, :fed_ed25519_public_key, :string
    add_column :groups, :fed_ed25519_private_key, :text
    add_column :groups, :fed_ed25519_public_key, :string

    # WebFinger delegation (§9.4): one domain binds at most one group, and the
    # subject must be unambiguous — hence the unique index.
    add_column :groups, :custom_domain, :string
    add_index :groups, :custom_domain, unique: true, where: "custom_domain IS NOT NULL"
  end
end
