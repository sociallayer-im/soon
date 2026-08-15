class CreateOauthGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_grants, id: :string do |t|
      t.string :user_id,        null: false
      t.string :application_id, null: false
      t.string :scopes,         null: false, default: [], array: true
      t.timestamps
    end

    add_index :oauth_grants, [ :user_id, :application_id ], unique: true
    add_foreign_key :oauth_grants, :users, column: :user_id
    add_foreign_key :oauth_grants, :oauth_applications, column: :application_id
  end
end
