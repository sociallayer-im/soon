class AddEventBrowseIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :events, :tags, using: :gin, algorithm: :concurrently
    add_index :comments, [:item_type, :item_id, :comment_type, :created_at, :id], name: "index_comments_for_newest_threads", where: "removed = false", algorithm: :concurrently
    add_index :topics, [:event_id, :created_at, :id], name: "index_topics_for_event_newest", algorithm: :concurrently
  end
end
