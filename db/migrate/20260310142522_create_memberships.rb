class CreateMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :memberships, id: :string do |t|
      t.references :user, null: false, foreign_key: true, type: :string
      t.references :group, null: false, foreign_key: true, type: :string
      t.string :role, null: false, comment: "member | admin | owner"
      t.boolean :active, default: true
      t.jsonb :data, default: {}
      t.timestamps
    end
    add_index :memberships, [:user_id, :group_id], unique: true
    add_index :memberships, [:group_id, :role]
  end
end
