class CreateTopics < ActiveRecord::Migration[8.1]
  def change
    create_table :topics, id: :string do |t|
      t.string   :group_id,    null: false
      t.string   :category_id, null: false
      t.string   :user_id,     null: false
      t.string   :title,       null: false
      t.text     :content
      t.string   :content_type, default: "text"
      t.string   :image_url
      t.string   :tags, default: [], array: true

      # Every state is a nullable timestamp rather than a status enum, so
      # there is only one place each fact lives — and so each one records
      # *when*. See design/DISCUSSION_PLAN.md 1.3.
      t.datetime :pinned_at
      t.datetime :closed_at
      t.datetime :flagged_at
      t.string   :flagged_by_id
      t.string   :flag_reason

      # Denormalised "last reply" cache. Topic#refresh_last_reply! is the only
      # writer; nothing else may touch these.
      t.string   :last_reply_id
      t.string   :last_reply_user_id
      t.datetime :replied_at
      t.integer  :replies_count,    null: false, default: 0
      t.integer  :stars_count,      null: false, default: 0
      t.bigint   :last_active_mark, null: false

      t.datetime :deleted_at
      t.string   :deleted_by_id
      t.timestamps

      # The list only ever selects live rows, so the sort indexes carry the
      # same condition — they stay the size of the visible set.
      t.index [:group_id, :last_active_mark],
        where: "deleted_at IS NULL AND flagged_at IS NULL",
        name: "index_topics_on_group_and_active"
      t.index [:category_id, :last_active_mark],
        where: "deleted_at IS NULL AND flagged_at IS NULL",
        name: "index_topics_on_category_and_active"
      t.index [:group_id, :pinned_at]
      t.index :user_id
      t.index :deleted_at
      t.index :flagged_at
      t.index :tags, using: :gin
    end
    add_foreign_key :topics, :groups
    add_foreign_key :topics, :categories
    add_foreign_key :topics, :users
  end
end
