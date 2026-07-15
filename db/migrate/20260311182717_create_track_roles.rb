class CreateTrackRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :track_roles, id: :string do |t|
      t.references :track, null: false, foreign_key: true, type: :string
      t.references :user, null: false, foreign_key: true, type: :string
      t.string :role, null: false, comment: "member | manager"
      t.timestamps
    end
    add_index :track_roles, [:track_id, :user_id], unique: true
  end
end
