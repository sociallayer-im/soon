class AddRegistrationReviewDetails < ActiveRecord::Migration[8.1]
  def change
    add_reference :participants, :reviewed_by, type: :string, foreign_key: {to_table: :users, on_delete: :nullify}
    add_column :participants, :reviewed_at, :datetime
    add_column :participants, :review_reason, :text
    add_column :participants, :cancellation_reason, :string
    add_column :participants, :payment_due_at, :datetime
    # Historical orders already reserved inventory at creation.
    add_column :ticket_items, :inventory_reserved, :boolean, default: true, null: false
    add_index :participants, [:event_id, :payment_due_at], where: "status = 'awaiting_payment'", name: 'idx_participants_payment_holds'
  end
end
