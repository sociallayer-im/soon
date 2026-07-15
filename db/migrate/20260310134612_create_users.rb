class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: :string do |t|
      t.string :name
      t.string :email
      t.string :phone
      t.string :eth
      t.string :image_url
      t.string :nickname
      t.string :telegram_id
      t.text   :bio
      t.boolean :active, default: true
      t.datetime :last_signin_at
      t.string :permissions, default: [], array: true
      t.jsonb :social_links, default: {}
      t.jsonb :data, default: {}
      t.timestamps
    end
    add_index :users, :name, unique: true
    add_index :users, :eth, unique: true
    add_index :users, :email, unique: true
    add_index :users, :phone, unique: true
  end
end
