class CreateDomains < ActiveRecord::Migration[8.1]
  def change
    create_table :domains, id: :string do |t|
      t.string :name, null: false
      t.string :fullname
      t.string :item_type
      t.string :item_id

      t.timestamps
    end
    add_index :domains, :name, unique: true
  end
end
