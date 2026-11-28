class CreateSodaIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :soda_identities do |t|
      t.references :user, type: :string, null: false, foreign_key: { on_delete: :cascade }
      t.string :issuer, null: false
      t.string :subject, null: false
      t.timestamps
    end
    add_index :soda_identities, [:issuer, :subject], unique: true
  end
end
