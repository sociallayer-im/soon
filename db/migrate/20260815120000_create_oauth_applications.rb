class CreateOauthApplications < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_applications, id: :string do |t|
      t.string  :client_id,            null: false
      # BCrypt digest. Public (SPA/native) clients have no secret at all — they
      # authenticate with PKCE alone — so this is nullable, unlike semi's.
      t.string  :client_secret_digest
      t.string  :name,                 null: false
      t.text    :description
      t.string  :logo_url
      t.string  :homepage_url
      t.string  :redirect_uris,        null: false, default: [], array: true
      t.string  :allowed_scopes,       null: false, default: [], array: true
      t.string  :status,               null: false, default: "draft"
      t.string  :owner_id,             null: false
      # An app may belong to a group rather than to its creator personally; the
      # consent screen shows whichever is set.
      t.string  :group_id
      t.boolean :confidential,         null: false, default: true
      # Skips the consent screen. Set in the database by hand only, like
      # users.admin — see design/OAUTH_PROVIDER_PLAN.md §9.
      t.boolean :trusted,              null: false, default: false
      t.datetime :reviewed_at
      t.timestamps
    end

    add_index :oauth_applications, :client_id, unique: true
    add_index :oauth_applications, :owner_id
    add_index :oauth_applications, :group_id
    add_foreign_key :oauth_applications, :users, column: :owner_id
    add_foreign_key :oauth_applications, :groups, column: :group_id
  end
end
