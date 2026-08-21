class CreateWithdrawals < ActiveRecord::Migration[8.1]
  # WeChat Pay runs single-merchant mode (WechatPaySetting#service_provider?
  # is unimplemented) — every organizer's WeChat revenue actually sits in the
  # platform's own merchant account, so it has to be settled out to them by
  # hand. This table is the request queue for that offline settlement, not a
  # payout integration: `status` moves pending -> completed/rejected only by
  # an operator, and `amount` snapshots what was owed at request time so a
  # later balance recalculation can't retroactively change what was promised.
  def change
    create_table :withdrawals, id: :string do |t|
      t.references :user, null: false, foreign_key: true, type: :string
      t.bigint :amount, null: false
      t.string :currency, null: false, default: "cny"
      t.string :status, null: false, default: "pending"
      t.string :bank_name, null: false
      t.string :bank_account_number, null: false
      t.string :bank_account_name, null: false
      t.text :note
      t.datetime :processed_at
      t.references :processed_by, foreign_key: { to_table: :users }, type: :string

      t.timestamps
    end

    add_index :withdrawals, [ :user_id, :status ]
  end
end
