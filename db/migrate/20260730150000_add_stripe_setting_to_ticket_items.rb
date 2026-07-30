class AddStripeSettingToTicketItems < ActiveRecord::Migration[8.1]
  def change
    # Snapshot of the key that took (or will take) the money, stamped at
    # order time. Refunds/verification resolve the account from here, never
    # from "current event owner" — key rotation or event transfer must not
    # misroute money (design/PAYMENTS_PLAN.md §2.1).
    add_column :ticket_items, :stripe_setting_id, :string
    add_index :ticket_items, :stripe_setting_id, where: "stripe_setting_id IS NOT NULL"
  end
end
