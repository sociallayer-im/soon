class LinkTopicsToEvents < ActiveRecord::Migration[8.1]
  def change
    add_reference :topics, :event, type: :string, foreign_key: true
    add_column :topics, :sync_to_community, :boolean, null: false, default: true
  end
end
