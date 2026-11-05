class CreateContentSafetyImages < ActiveRecord::Migration[8.0]
  def change
    create_table :content_safety_images, id: :string do |t|
      t.string :url, null: false
      t.string :sha256, null: false
      t.timestamps
    end
    add_index :content_safety_images, :url, unique: true
  end
end
