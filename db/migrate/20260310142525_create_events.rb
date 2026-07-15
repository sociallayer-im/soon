class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events, id: :string do |t|
      t.string :title
      t.string :slug
      t.string   :image_url
      t.datetime :start_time
      t.datetime :end_time
      t.string :timezone

      t.text    :content
      t.references :place, null: true, foreign_key: false, type: :string
      t.string :meeting_url
      t.string :external_url

      t.string :status, default: "draft", comment: "draft | pending | published | archived | closed | cancelled"
      t.string :visibility, default: "public", comment: "public | private"
      t.boolean :pinned, default: false

      t.integer :max_participant
      t.integer :participant_count, default: 0
      t.boolean :require_approval, default: false

      t.string :category
      t.string :kind
      t.string :tags, array: true, default: []
      t.string :recurring_id
      t.string :requirement_tags, array: true
      t.text :notes

      t.references :owner, null: false, foreign_key: { to_table: :users }, type: :string
      t.references :group, null: false, foreign_key: true, type: :string
      t.references :track, null: true, foreign_key: false, type: :string
      t.references :venue, null: true, foreign_key: false, type: :string

      t.string :op_status
      t.string :op_priority
      t.string :op_labels, default: [], array: true
      t.string :op_assigned_users, default: [], array: true

      t.timestamps
    end
  end
end
