class CreateVenues < ActiveRecord::Migration[8.1]
  def change
    create_table :venues, id: :string do |t|
      t.string :name, null: false
      t.references :place, null: true, foreign_key: true, type: :string
      t.integer :capacity
      t.text :about
      t.string :website
      t.references :group, null: false, foreign_key: true, type: :string
      t.references :owner, null: false, foreign_key: { to_table: :users }, type: :string
      t.jsonb :timeslots
      t.jsonb :overrides
      t.string :amenities, default: [], array: true
      t.string :tags, array: true, default: []
      t.boolean :require_approval, default: false
      t.string :image_urls, default: [], array: true
      t.string :featured_image_url
      t.string :track_ids, default: [], array: true
      t.timestamps
    end
    add_index :venues, :name, unique: true
  end
end
