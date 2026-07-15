class CreateCoupons < ActiveRecord::Migration[8.1]
  def change
    create_table :coupons, id: :string do |t|
      t.string :selector_type, comment: "code | email | badge"
      t.string :label
      t.string :code
      t.string :receiver_address
      t.string :discount_type, comment: "ratio | amount"
      t.integer :discount, comment: "basis points of 10000 for ratio, smallest unit for amount"
      t.references :event, null: false, foreign_key: true, type: :string
      t.string :applicable_ticket_ids, array: true
      t.string :ticket_item_ids, array: true
      t.datetime :expires_at
      t.integer :max_allowed_usages
      t.integer :order_usage_count, default: 0
      t.boolean :removed, default: false

      t.timestamps
    end
  end
end
