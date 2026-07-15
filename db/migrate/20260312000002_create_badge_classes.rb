class CreateBadgeClasses < ActiveRecord::Migration[8.1]
  def change
    create_table :badge_classes, id: :string do |t|
      t.string :name, null: false
      t.string :title, null: false
      t.text :metadata
      t.text :content
      t.string :image_url
      t.references :creator, null: false, foreign_key: { to_table: :users }, type: :string
      t.references :group, null: true, foreign_key: true, type: :string
      t.integer :counter, default: 1
      t.string :hashtags, array: true
      t.boolean :transferable, default: false, null: false
      t.boolean :revocable, default: false, null: false
      t.boolean :weighted, default: false, null: false
      t.boolean :encrypted, default: false, null: false
      t.string :badge_type, default: "badge", null: false, comment: "badge | nft | nftpass | private"
      t.string :permissions, default: [], array: true
      t.string :display, default: "normal", comment: "normal | hidden | pinned"
      t.string :domain
      t.string :status, default: "active", comment: "active | freezed"
      t.string :can_send_badge, default: "owner", comment: "owner | group_member_send"

      t.timestamps
    end
  end
end
