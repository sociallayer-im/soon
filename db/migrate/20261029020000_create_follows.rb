# A user following another user or a group. This is the product graph the
# clients already call (`GET/POST /api/v1/follows`). It is not `fed_follows`,
# which belongs to the federation actor graph.
class CreateFollows < ActiveRecord::Migration[8.1]
  def change
    create_table :follows, id: :string do |t|
      t.references :user, type: :string, null: false, foreign_key: true, index: false
      t.string :target_type, null: false
      t.string :target_id, null: false
      t.string :status, null: false, default: "active"
      t.timestamps
    end

    add_index :follows, [ :user_id, :target_type, :target_id ], unique: true
    add_index :follows, [ :target_type, :target_id, :created_at ]
    add_check_constraint :follows, "status IN ('active', 'pending', 'declined')", name: "follows_status_valid"
    add_check_constraint :follows, "target_type IN ('User', 'Group')", name: "follows_target_type_valid"
    add_check_constraint :follows, "NOT (target_type = 'User' AND target_id = user_id)", name: "follows_no_self"
  end
end
