class CreateRefundRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :refund_requests, id: :string do |t|
      t.references :ticket_item, type: :string, null: false, foreign_key: true
      t.references :user, type: :string, null: false, foreign_key: true
      t.references :reviewed_by, type: :string, foreign_key: {to_table: :users}
      t.references :refund, type: :string, foreign_key: true, index: {unique: true}
      t.string :status, null: false, default: "requested"
      t.text :reason
      t.text :review_reason
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :refund_requests, :ticket_item_id, unique: true, where: "status IN ('requested','processing')", name: "index_refund_requests_one_open"
    add_index :refund_requests, [:status, :created_at, :id]
  end
end
