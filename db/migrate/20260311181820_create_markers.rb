class CreateMarkers < ActiveRecord::Migration[8.1]
  def change
    create_table :markers, id: :string do |t|
      t.references :place, null: false, foreign_key: true, type: :string
      t.references :group, null: false, foreign_key: true, type: :string
      t.references :owner, null: false, foreign_key: { to_table: :users }, type: :string
      t.string :category
      t.string :pin_image_url
      t.string :cover_image_url
      t.string :title, null: false
      t.text :about
      t.string :link
      t.string :status
      t.jsonb :data, default: {}

      t.timestamps
    end
  end
end
