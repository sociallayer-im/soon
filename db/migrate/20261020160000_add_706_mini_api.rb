class Add706MiniApi < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :city, :string
    add_index :events, :city

    add_column :groups, :city, :string
    add_index :groups, :city

    add_column :users, :wechat_mini_openid, :string
    add_index :users, :wechat_mini_openid, unique: true, where: "wechat_mini_openid IS NOT NULL"

    change_column_comment :comments, :comment_type,
      from: "checkin | chat | comment | star | feedback",
      to: "checkin | chat | comment | star | feedback | recommendation"

    create_table :follows, id: :string do |t|
      t.string :user_id, null: false
      t.string :target_type, null: false
      t.string :target_id, null: false
      t.string :status, null: false, default: "active"
      t.timestamps
      t.index [:user_id, :target_type, :target_id], unique: true
      t.index :user_id
    end
    add_foreign_key :follows, :users

    create_table :blocks, id: :string do |t|
      t.string :user_id, null: false
      t.string :target_user_id, null: false
      t.datetime :created_at, null: false
      t.index [:user_id, :target_user_id], unique: true
      t.index :target_user_id
    end
    add_foreign_key :blocks, :users
    add_foreign_key :blocks, :users, column: :target_user_id

    create_table :reports, id: :string do |t|
      t.string :user_id, null: false
      t.string :target_type, null: false
      t.string :target_id
      t.string :reason, null: false
      t.string :status, null: false, default: "open"
      t.string :resolved_by_id
      t.text :note
      t.timestamps
      t.index :user_id
      t.index :status
    end
    add_foreign_key :reports, :users
    add_foreign_key :reports, :users, column: :resolved_by_id

    create_table :campaigns, id: :string do |t|
      t.string :owner_id, null: false
      t.string :group_id
      t.string :title, null: false
      t.string :kicker
      t.text :introduction
      t.string :featured_image_url
      t.string :event_ids, array: true, null: false, default: []
      t.string :status, null: false, default: "draft"
      t.integer :round, null: false, default: 1
      t.timestamps
      t.index :owner_id
      t.index :group_id
      t.index :status
    end
    add_foreign_key :campaigns, :users, column: :owner_id
    add_foreign_key :campaigns, :groups

    create_table :reviews, id: :string do |t|
      t.string :campaign_id, null: false
      t.integer :round, null: false
      t.string :scope, null: false, default: "creator"
      t.string :status, null: false, default: "pending"
      t.text :note
      t.jsonb :snapshot, null: false, default: {}
      t.string :decided_by_id
      t.timestamps
      t.index :campaign_id
      t.index [:campaign_id, :status]
    end
    add_foreign_key :reviews, :campaigns
    add_foreign_key :reviews, :users, column: :decided_by_id
  end
end
