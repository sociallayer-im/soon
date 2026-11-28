class CreateContentReports < ActiveRecord::Migration[8.0]
  def change
    create_table :content_reports do |t|
      t.string :reporter_id, null: false
      t.string :target_type, null: false
      t.string :target_id, null: false
      t.string :reason, null: false
      t.string :status, null: false, default: "pending"
      t.string :decision
      t.text :review_note
      t.string :reviewer_id
      t.datetime :restored_at
      t.string :restored_by_id
      t.text :restore_note
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :content_reports, [:status, :created_at, :id]
    add_index :content_reports, [:reporter_id, :target_type, :target_id], unique: true, where: "status = 'pending'", name: "index_content_reports_pending_unique"
    add_column :events, :moderated_at, :datetime
    add_column :events, :moderation_reason, :text
    add_column :events, :moderated_by_id, :string
  end
end
