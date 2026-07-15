class CreateVouchers < ActiveRecord::Migration[8.1]
  def change
    create_table :vouchers, id: :string do |t|
      t.references :sender, null: false, foreign_key: { to_table: :users }, type: :string
      t.references :badge_class, null: false, foreign_key: true, type: :string
      t.string :badge_title
      t.string :badge_content
      t.string :badge_image
      t.string :code
      t.string :message
      t.datetime :expires_at
      t.integer :counter, default: 1
      t.string :receiver_id
      t.string :receiver_address
      t.string :receiver_address_type, comment: "id | email | address"
      t.string :strategy, default: "code", comment: "code | account | address | email | event | remember"
      t.jsonb :data

      t.timestamps
    end
    add_index :vouchers, :receiver_id
    add_foreign_key :vouchers, :users, column: :receiver_id
  end
end
