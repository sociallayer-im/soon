class AddPaymentColumnsToTicketItems < ActiveRecord::Migration[8.1]
  def up
    change_table :ticket_items, bulk: true do |t|
      t.string :payment_provider, comment: "stripe | evm | free"
      t.string :provider_ref, comment: "Checkout Session / PaymentIntent id for stripe; txhash stays the crypto column"
      t.string :currency
      t.datetime :reserved_until, comment: "sweeper expires unpaid orders past this"
      t.datetime :released_at, comment: "inventory released exactly once, guarded here — never inferred from status"
      t.datetime :paid_at
    end
    add_index :ticket_items, [ :status, :reserved_until ], name: "index_ticket_items_sweeper"
    add_index :ticket_items, :provider_ref, unique: true, where: "provider_ref IS NOT NULL"

    # Backfill existing orders. chain='stripe' rows kept the PaymentIntent id
    # in txhash — copy it over; crypto rows keep txhash as their reference.
    execute <<~SQL
      UPDATE ticket_items SET
        payment_provider = CASE
          WHEN chain = 'stripe' THEN 'stripe'
          WHEN chain IS NOT NULL THEN 'evm'
          ELSE 'free'
        END,
        currency = CASE WHEN chain = 'stripe' THEN 'usd' END,
        provider_ref = CASE WHEN chain = 'stripe' THEN txhash END,
        paid_at = CASE WHEN status = 'succeeded' THEN updated_at END
    SQL
  end

  def down
    remove_index :ticket_items, name: "index_ticket_items_sweeper"
    remove_index :ticket_items, :provider_ref
    change_table :ticket_items, bulk: true do |t|
      t.remove :payment_provider, :provider_ref, :currency, :reserved_until, :released_at, :paid_at
    end
  end
end
