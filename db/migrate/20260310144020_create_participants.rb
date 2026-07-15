class CreateParticipants < ActiveRecord::Migration[8.1]
  def change
    create_table :participants, id: :string do |t|
      t.references :user, null: false, foreign_key: true, type: :string
      t.references :event, null: false, foreign_key: true, type: :string
      t.string :status, null: false, default: "attending", comment: "attending | declined | maybe"

      t.timestamps
    end
    add_index :participants, [:user_id, :event_id], unique: true
  end
end
