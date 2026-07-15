class CreatePaymentMethods < ActiveRecord::Migration[8.1]
  def change
    create_table :payment_methods, id: :string do |t|
      t.string :item_type
      t.string :item_id
      t.string :chain
      t.string :kind, comment: "crypto | fiat | credit"
      t.string :token_name
      t.string :token_address
      t.string :receiver_address
      t.bigint :price
      t.string :protocol
      t.string :chains, default: [], array: true
      t.jsonb :chain_token_addresses, default: {}

      t.timestamps
    end
    add_index :payment_methods, [:item_type, :item_id]
  end
end
