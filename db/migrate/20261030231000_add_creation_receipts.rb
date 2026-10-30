class AddCreationReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :creation_receipts, id: :string do |t|
      t.references :user, type: :string, null: false, foreign_key: {on_delete: :cascade}
      t.string :request_key, null: false
      t.string :fingerprint, null: false
      t.integer :response_status, null: false
      t.text :response_body, null: false
      t.timestamps
    end
    add_index :creation_receipts, [:user_id, :request_key], unique: true
  end
end
