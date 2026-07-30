class AddStripeSettingToPaymentMethods < ActiveRecord::Migration[8.1]
  def change
    change_table :payment_methods, bulk: true do |t|
      t.string :stripe_setting_id, comment: "which of the event owner's keys this method charges to"
      t.string :currency
    end
    add_index :payment_methods, :stripe_setting_id
  end
end
