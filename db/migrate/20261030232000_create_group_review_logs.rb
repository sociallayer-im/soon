class CreateGroupReviewLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :group_review_logs, id: :string do |t|
      t.references :group, type: :string, null: false, foreign_key: true
      t.references :reviewer, type: :string, foreign_key: {to_table: :users, on_delete: :nullify}
      t.string :decision, null: false
      t.text :reason
      t.timestamps
    end
    reversible do |direction|
      direction.up do
        execute <<~SQL
          INSERT INTO group_review_logs (id, group_id, reviewer_id, decision, reason, created_at, updated_at)
          SELECT id || '-initial-review', id, reviewed_by_id, review_status, review_reason, reviewed_at, reviewed_at
          FROM groups WHERE reviewed_at IS NOT NULL AND review_status IN ('approved', 'rejected')
        SQL
      end
    end
  end
end
