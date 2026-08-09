class CreateWechatPayEvents < ActiveRecord::Migration[8.1]
  def change
    # Callback idempotency + audit store, mirroring stripe_events. The primary
    # key is WeChat's own notification id, so a redelivery fails the insert and
    # is thereby recognised as already seen.
    #
    # This matters more here than it does for Stripe: WeChat retries a callback
    # up to 15 times over 24 hours (15s, 15s, 30s, 3m, 10m, 20m, 30m×3, 60m,
    # 3h×3, 6h×2) and treats any response slower than 5 seconds as a failure,
    # so duplicate deliveries are the normal case rather than an edge one.
    create_table :wechat_pay_events, id: :string do |t|
      t.string :wechat_pay_setting_id, null: false, comment: "which merchant's endpoint received it"
      t.string :event_type, null: false, comment: "TRANSACTION.SUCCESS | REFUND.SUCCESS | REFUND.ABNORMAL | REFUND.CLOSED"
      t.jsonb :payload, null: false, default: {}, comment: "envelope with resource replaced by its decrypted contents"
      t.datetime :processed_at
      t.text :error
      t.timestamps
      t.index :wechat_pay_setting_id
      t.index [ :event_type, :created_at ]
    end
  end
end
