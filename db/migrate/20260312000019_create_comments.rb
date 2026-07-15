class CreateComments < ActiveRecord::Migration[8.1]
  def change
    create_table :comments, id: :string do |t|
      t.string :title
      t.string :item_type
      t.string :item_id
      t.string :reply_parent_id
      t.text :content
      t.string :content_type, default: "text"
      t.references :user, null: false, foreign_key: true, type: :string
      t.boolean :removed, default: false
      t.string :comment_type, null: false, comment: "checkin | chat | comment | star | feedback"
      t.string :icon_url
      t.string :edit_parent_id
      t.string :badge_id

      t.timestamps
    end
    add_index :comments, [:item_type, :item_id, :removed]
    add_index :comments, [:user_id, :comment_type]
    add_foreign_key :comments, :badges
    add_foreign_key :comments, :comments, column: :reply_parent_id
    add_foreign_key :comments, :comments, column: :edit_parent_id
  end
end
