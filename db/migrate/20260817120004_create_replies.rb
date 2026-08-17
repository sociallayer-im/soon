class CreateReplies < ActiveRecord::Migration[8.1]
  def change
    create_table :replies, id: :string do |t|
      t.string   :topic_id,    null: false
      t.string   :user_id,     null: false
      # A weak pointer at another reply in the same topic, for "in reply to
      # @someone" — not a tree. Nullable and deliberately without a foreign
      # key: the referenced reply may be gone.
      t.string   :reply_to_id
      t.text     :content,     null: false
      t.string   :content_type, default: "text"

      t.datetime :flagged_at
      t.string   :flagged_by_id
      t.string   :flag_reason
      t.datetime :deleted_at
      t.string   :deleted_by_id

      t.timestamps
      t.index [:topic_id, :created_at],
        where: "deleted_at IS NULL AND flagged_at IS NULL",
        name: "index_replies_on_topic_and_created_alive"
      t.index [:topic_id, :created_at]
      t.index :reply_to_id
      t.index :user_id
      t.index :deleted_at
      t.index :flagged_at
    end
    add_foreign_key :replies, :topics
    add_foreign_key :replies, :users
  end
end
