class CreateTicketItems < ActiveRecord::Migration[8.1]
  def change
    create_table :ticket_items, id: :string do |t|
      t.string :status, comment: "pending | unbounded | succeeded | cancelled | timeout"
      t.references :user, null: true, foreign_key: true, type: :string
      t.references :ticket, null: false, foreign_key: true, type: :string
      t.references :event, null: true, foreign_key: true, type: :string
      t.string :chain
      t.string :txhash
      t.integer :amount
      t.integer :discount_value
      t.string :discount_data
      t.references :participant, null: true, foreign_key: true, type: :string
      t.string :ticket_type, default: "event", comment: "event | group"
      t.string :group_id
      t.string :auth_type, comment: "free | payment | badge | invite"
      t.string :tracks_allowed, array: true
      t.references :payment_method, null: true, foreign_key: true, type: :string
      t.references :coupon, null: true, foreign_key: true, type: :string
      t.string :sender_address
      t.string :selector_type
      t.string :selector_address
      t.decimal :original_price, precision: 40
      t.string :protocol

      t.timestamps
    end
    add_index :ticket_items, [:event_id, :status]
    add_index :ticket_items, [:user_id, :status]
    add_foreign_key :ticket_items, :groups
  end
end
