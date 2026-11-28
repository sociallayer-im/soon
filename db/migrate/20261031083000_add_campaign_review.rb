class AddCampaignReview < ActiveRecord::Migration[8.1]
  def change
    # Existing campaigns keep their published state; new submissions require review.
    add_column :campaigns, :review_status, :string, null: false, default: "approved"
    change_column_default :campaigns, :review_status, from: "approved", to: "pending"
    add_column :campaigns, :review_reason, :text
    add_column :campaigns, :reviewed_at, :datetime
    add_reference :campaigns, :reviewed_by, type: :string, foreign_key: {to_table: :users}
    add_index :campaigns, [:review_status, :created_at, :id]
    add_index :campaigns, [:status, :review_status, :created_at, :id], name: "index_campaigns_public_review"
    create_table :campaign_review_logs, id: :string do |t|
      t.references :campaign, type: :string, null: false, foreign_key: true
      t.references :reviewer, type: :string, foreign_key: {to_table: :users}
      t.string :decision, null: false
      t.text :reason
      t.timestamps
    end
  end
end
