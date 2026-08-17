class CreateCategoryMembers < ActiveRecord::Migration[8.1]
  def change
    # Only used by visibility: "invited". The other three tiers read the
    # memberships that already exist rather than materialising a copy of them.
    create_table :category_members, id: :string do |t|
      t.string :category_id, null: false
      t.string :user_id,     null: false
      t.timestamps
      t.index [:category_id, :user_id], unique: true
      t.index :user_id
    end
    add_foreign_key :category_members, :categories
    add_foreign_key :category_members, :users
  end
end
