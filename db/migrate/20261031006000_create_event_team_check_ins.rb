class CreateEventTeamCheckIns < ActiveRecord::Migration[8.1]
  def change
    create_table :event_team_check_ins, id: :string do |t|
      t.references :event, type: :string, null: false, foreign_key: {on_delete: :cascade}
      t.references :user, type: :string, null: false, foreign_key: {on_delete: :cascade}
      t.datetime :checked_in_at, null: false
      t.timestamps
    end
    add_index :event_team_check_ins, [:event_id, :user_id], unique: true
  end
end
