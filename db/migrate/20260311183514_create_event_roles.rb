class CreateEventRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :event_roles, id: :string do |t|
      t.references :event, null: false, foreign_key: true, type: :string
      t.string :item_id
      t.string :item_type, null: false, comment: "user | group"
      t.string :role, null: false, comment: "member | manager"
      t.string :email
      t.string :display_name
      t.string :image_url

      t.timestamps
    end
    add_index :event_roles, [:event_id, :item_id, :item_type], unique: true
  end
end
