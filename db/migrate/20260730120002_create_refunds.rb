class CreateRefunds < ActiveRecord::Migration[8.1]
  def change
    # A refund is written as `pending` when the organizer initiates it and
    # finalized (succeeded/failed) by the charge.refunded webhook or the
    # sweeper — never synchronously, refunds can fail asynchronously.
    # See design/PAYMENTS_PLAN.md Phase 7.
    create_table :refunds, id: :string do |t|
      t.string :ticket_item_id, null: false
      t.string :provider_ref, comment: "Stripe re_… id"
      t.integer :amount, null: false, comment: "minor units; equal to the item amount for a full refund"
      t.string :currency, null: false, default: "usd"
      t.boolean :full_refund, null: false, default: true, comment: "full refunds release the seat; partial move money only"
      t.string :reason
      t.string :status, null: false, default: "pending", comment: "pending | succeeded | failed"
      t.string :requested_by_user_id, null: false
      t.text :error
      t.timestamps
      t.index :ticket_item_id
      # Concurrent-click guard (PAYMENTS_PLAN §6.4): at most one live full
      # refund per order — the second click hits this index, not Stripe.
      t.index :ticket_item_id, unique: true,
        where: %(full_refund AND status IN ('pending','succeeded')),
        name: "index_refunds_one_live_full_refund_per_item"
    end
  end
end
