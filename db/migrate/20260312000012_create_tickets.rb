class CreateTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :tickets, id: :string do |t|
      t.string :title
      t.string :content
      t.references :event, null: false, foreign_key: true, type: :string
      t.string :check_badge_class_id
      t.integer :quantity
      t.datetime :end_time
      t.boolean :need_approval
      t.string :status, default: "normal", comment: "normal | nosale | hidden | inactive"
      t.string :ticket_type, default: "event", comment: "event | group"
      t.string :group_id
      t.date :start_date
      t.date :end_date
      t.date :days_allowed, array: true
      t.string :tracks_allowed, default: [], array: true

      t.timestamps
    end
    add_index :tickets, [:event_id, :status]
    add_index :tickets, [:group_id, :status]
    add_foreign_key :tickets, :groups
    add_foreign_key :tickets, :badge_classes, column: :check_badge_class_id
  end
end
