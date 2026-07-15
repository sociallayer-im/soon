class CreateTracks < ActiveRecord::Migration[8.1]
  def change
    create_table :tracks, id: :string do |t|
      t.references :group, null: false, foreign_key: true, type: :string
      t.string :name, null: false
      t.string :title, null: false
      t.string :image_url
      t.boolean :is_private
      t.text :description
      t.date :start_date
      t.date :end_date
      t.timestamps
    end
  end
end
