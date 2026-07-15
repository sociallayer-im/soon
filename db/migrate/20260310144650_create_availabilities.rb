class CreateAvailabilities < ActiveRecord::Migration[8.1]
  def change
    create_table :availabilities, id: :string do |t|
      t.string :item_id, null: false
      t.string :item_type, null: false
      t.string :day_of_week
      t.date :day
      t.jsonb :intervals, default: {}
      t.string :role_required

      t.timestamps
    end
    add_index :availabilities, [:item_id, :item_type, :day]
  end
end
