class CreateWechatPaySettings < ActiveRecord::Migration[8.1]
  def change
    # The merchant account a WeChat Pay order is collected by.
    #
    # CN launches on one platform-owned merchant (design/WECHAT_INTEGRATION.md
    # §2.2 path (a)), so in practice this table holds a single row with a null
    # user_id. It is a table rather than a handful of env vars because orders
    # must snapshot the account that took the money — a refund is issued
    # against that mchid, not against whatever is configured today — and
    # because moving to the 服务商 model later then means inserting rows and
    # filling sub_mchid, not writing a migration and backfilling live orders.
    create_table :wechat_pay_settings, id: :string do |t|
      t.string :user_id, comment: "null = platform-owned (single-merchant mode); set = per-organizer sub-merchant"
      t.string :name, null: false, comment: "label, e.g. the registered merchant name"
      t.string :mchid, null: false, comment: "商户号"
      t.string :sub_mchid, comment: "特约商户号 — 服务商 mode only, null in single-merchant mode"
      t.string :app_id, null: false, comment: "the 公众号 appid; MUST be the one that issued payer.openid"
      t.string :cert_serial, null: false, comment: "商户API证书序列号, sent as the signature's serial_no"
      t.text :private_key, null: false, comment: "apiclient_key.pem contents; signs every outbound request"
      t.text :apiv3_key, null: false, comment: "32-byte APIv3 key; AES-256-GCM-decrypts callback resources"
      t.string :public_key_id, comment: "微信支付公钥 ID (PUB_KEY_ID_…), sent as Wechatpay-Serial on callbacks"
      t.text :public_key, comment: "微信支付公钥 PEM; verifies callback signatures"
      t.string :currency, null: false, default: "cny"
      t.string :status, null: false, default: "active", comment: "active | invalid"
      t.timestamps
      t.index :user_id
      # One row per merchant account. Also what makes the install task safely
      # re-runnable after a credential rotation.
      t.index [ :mchid, :sub_mchid ], unique: true
    end

    # Which merchant collects this ticket's WeChat payments. Unlike Stripe's
    # per-organizer keys the organizer does not choose one — there is exactly
    # one — but the column is still per-method so that stays true by data
    # rather than by assumption.
    add_column :payment_methods, :wechat_pay_setting_id, :string,
      comment: "which merchant collects this method's WeChat payments"

    # The snapshot. Refunds, query-order verification and webhook attribution
    # all resolve the merchant from HERE, never from the current config.
    add_column :ticket_items, :wechat_pay_setting_id, :string,
      comment: "the merchant that took the money; refunds go back through it"
    add_index :ticket_items, :wechat_pay_setting_id
  end
end
