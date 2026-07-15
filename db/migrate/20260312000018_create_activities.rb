class CreateActivities < ActiveRecord::Migration[8.1]
  def change
    create_table :activities, id: :string do |t|
      t.string :action, null: false
      t.string :item_type
      t.string :item_id
      t.references :initiator, null: false, foreign_key: { to_table: :users }, type: :string
      t.string :receiver_id
      t.string :receiver_address
      t.jsonb :payload, default: {}
      t.boolean :has_read, default: false

      t.datetime :created_at, null: false
    end
    add_index :activities, [:item_type, :item_id]
    add_index :activities, :receiver_id
    add_index :activities, :created_at
    add_foreign_key :activities, :users, column: :receiver_id
  end
end
