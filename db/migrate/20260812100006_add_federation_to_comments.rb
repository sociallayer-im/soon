class AddFederationToComments < ActiveRecord::Migration[8.1]
  # Remote comments (Note inReplyTo an event) land in the same table as local
  # ones so one comment thread renders both (design/FEDERATION_PLAN.md §2.4).
  def change
    add_column :comments, :fed_actor_id, :string
    add_column :comments, :fed_uri, :string

    change_column_null :comments, :user_id, true
    add_index :comments, :fed_uri, unique: true, where: "fed_uri IS NOT NULL"
  end
end
