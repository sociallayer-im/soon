class CreateRecurrings < ActiveRecord::Migration[8.1]
  def change
    create_table :recurrings, id: :string do |t|
      t.datetime :start_time, null: false
      t.datetime :end_time
      t.string :interval, null: false
      t.integer :event_count, default: 0
      t.string :timezone

      t.timestamps
    end
  end
end
