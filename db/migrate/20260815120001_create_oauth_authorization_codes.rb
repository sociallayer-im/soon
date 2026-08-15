class CreateOauthAuthorizationCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_authorization_codes, id: :string do |t|
      # SHA-256 of the code. The plaintext leaves the server exactly once, in
      # the authorize response — a database dump must not be replayable.
      # Named token_digest, not code_digest, so the three credential models can
      # share OauthDigestible.
      t.string   :token_digest,          null: false
      t.string   :user_id,               null: false
      t.string   :application_id,        null: false
      t.string   :scopes,                null: false, default: [], array: true
      t.string   :redirect_uri,          null: false
      t.string   :code_challenge,        null: false
      t.string   :code_challenge_method, null: false, default: "S256"
      # OIDC: echoed into the id_token so the client can bind it to its own
      # session. semi's implementation omitted this entirely.
      t.string   :nonce
      t.datetime :expires_at,            null: false
      t.datetime :used_at
      t.timestamps
    end

    add_index :oauth_authorization_codes, :token_digest, unique: true
    add_index :oauth_authorization_codes, :user_id
    add_index :oauth_authorization_codes, :application_id
    add_foreign_key :oauth_authorization_codes, :users, column: :user_id
    add_foreign_key :oauth_authorization_codes, :oauth_applications, column: :application_id
  end
end
