class CreateStripeSettings < ActiveRecord::Migration[8.1]
  def change
    # One row per Stripe API key. A user may hold several (live/test, or
    # different accounts for different events); the key a ticket charges to is
    # chosen at ticket-creation time (payment_methods.stripe_setting_id).
    # See design/PAYMENTS_PLAN.md §2.1.
    create_table :stripe_settings, id: :string do |t|
      t.string :user_id, null: false
      t.string :name, null: false, comment: "user-facing label shown in key pickers"
      t.text :secret_key, null: false, comment: "plaintext by decision; only the masked tail ever leaves the server"
      t.text :webhook_secret, comment: "per-endpoint signing secret"
      t.string :webhook_endpoint_id, comment: "Stripe we_… id, for deletion on key removal"
      t.string :account_id, comment: "Stripe acct_…, captured at validation time"
      t.string :mode, null: false, default: "live", comment: "live | test — auto-detected from key prefix"
      t.string :currency, null: false, default: "usd"
      t.string :status, null: false, default: "active", comment: "active | invalid"
      t.timestamps
      t.index :user_id
    end
  end
end
