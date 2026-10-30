class AddGroupReview < ActiveRecord::Migration[8.1]
  def change
    add_column :groups, :review_status, :string, null: false, default: "approved"
    add_column :groups, :review_reason, :text
    add_column :groups, :reviewed_at, :datetime
    add_reference :groups, :reviewed_by, type: :string, foreign_key: {to_table: :users, on_delete: :nullify}
    add_index :groups, [:review_status, :created_at]
    add_check_constraint :groups, "review_status IN ('pending', 'approved', 'rejected')", name: "groups_review_status"
  end
end
