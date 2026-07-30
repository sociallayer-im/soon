class CreateStripeEvents < ActiveRecord::Migration[8.1]
  def change
    # Webhook idempotency + audit store. The primary key is Stripe's own
    # event id (evt_…) — a duplicate delivery fails the insert and is thereby
    # recognized as already seen. See design/PAYMENTS_PLAN.md §2.3.
    create_table :stripe_events, id: :string do |t|
      t.string :stripe_setting_id, null: false, comment: "which key's endpoint received it"
      t.string :event_type, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :processed_at
      t.text :error
      t.timestamps
      t.index :stripe_setting_id
      t.index [ :event_type, :created_at ]
    end
  end
end
