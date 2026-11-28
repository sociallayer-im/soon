class CreateCampaignsAndGroupCity < ActiveRecord::Migration[8.1]
  def change
    add_column :groups, :city, :string
    add_index :groups, :city
    create_table :campaigns, id: :string do |t|
      t.references :group, type: :string, null: false, foreign_key: true
      t.references :owner, type: :string, null: false, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.string :kicker
      t.text :introduction
      t.string :cover_url
      t.jsonb :media, null: false, default: []
      t.string :resource_links, array: true, null: false, default: []
      t.string :status, null: false, default: "draft"
      t.timestamps
    end
    add_index :campaigns, [:group_id, :status]
    create_table :campaign_events, id: :string do |t|
      t.references :campaign, type: :string, null: false, foreign_key: true
      t.references :event, type: :string, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :campaign_events, [:campaign_id, :event_id], unique: true
  end
end
