class CreateOauthRefreshTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_refresh_tokens, id: :string do |t|
      t.string   :token_digest,    null: false
      t.string   :user_id,         null: false
      t.string   :application_id,  null: false
      t.string   :access_token_id, null: false
      # Every token descended from one authorization survives with the same
      # family_id. Presenting an already-rotated token means the chain leaked,
      # so the whole family is burned rather than just that one token.
      t.string   :family_id,       null: false
      t.datetime :expires_at,      null: false
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :oauth_refresh_tokens, :token_digest, unique: true
    add_index :oauth_refresh_tokens, :family_id
    add_index :oauth_refresh_tokens, :access_token_id
    add_foreign_key :oauth_refresh_tokens, :users, column: :user_id
    add_foreign_key :oauth_refresh_tokens, :oauth_applications, column: :application_id
    add_foreign_key :oauth_refresh_tokens, :oauth_access_tokens, column: :access_token_id
  end
end
