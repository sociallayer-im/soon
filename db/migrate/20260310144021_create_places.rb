class CreatePlaces < ActiveRecord::Migration[8.1]
  def change
    create_table :places, id: :string do |t|
      t.string :name, null: false
      t.string :address
      t.decimal :latitude, precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6
      t.text :description

      t.timestamps
    end
    add_index :places, :name, unique: true
  end
end
