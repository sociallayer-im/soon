class CreateForms < ActiveRecord::Migration[8.1]
  def change
    create_table :forms, id: :string do |t|
      t.string :title, null: false
      t.text :description
      t.string :slug, null: false
      t.boolean :published, default: false, null: false
      t.text :submission_message
      t.string :created_by_id

      t.timestamps
    end
    add_index :forms, :slug, unique: true
    add_index :forms, :created_by_id
  end
end
