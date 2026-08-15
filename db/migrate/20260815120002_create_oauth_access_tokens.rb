class CreateOauthAccessTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_access_tokens, id: :string do |t|
      t.string   :token_digest,   null: false
      t.string   :user_id,        null: false
      t.string   :application_id, null: false
      t.string   :scopes,         null: false, default: [], array: true
      t.datetime :expires_at,     null: false
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :oauth_access_tokens, :token_digest, unique: true
    add_index :oauth_access_tokens, [ :user_id, :application_id ]
    add_index :oauth_access_tokens, :application_id
    add_foreign_key :oauth_access_tokens, :users, column: :user_id
    add_foreign_key :oauth_access_tokens, :oauth_applications, column: :application_id
  end
end
