class CreateCategories < ActiveRecord::Migration[8.1]
  def change
    # NOT a site-wide taxonomy: a category is one group's discussion board,
    # which is why group_id is null: false. See design/DISCUSSION_PLAN.md 1.0.
    create_table :categories, id: :string do |t|
      t.string   :group_id,     null: false
      t.string   :name,         null: false
      t.string   :slug,         null: false
      t.string   :summary
      t.integer  :sort,         null: false, default: 0
      t.integer  :topics_count, null: false, default: 0
      t.boolean  :archived,     null: false, default: false
      t.string   :visibility,   null: false, default: "public",
        comment: "public | member | manager | invited"
      t.timestamps
      t.index [:group_id, :slug], unique: true
      t.index [:group_id, :sort]
      t.index [:group_id, :visibility]
    end
    add_foreign_key :categories, :groups
  end
end
