class CreateBadges < ActiveRecord::Migration[8.1]
  def change
    create_table :badges, id: :string do |t|
      t.integer :index
      t.references :badge_class, null: false, foreign_key: true, type: :string
      t.references :creator, null: false, foreign_key: { to_table: :users }, type: :string
      t.references :owner, null: false, foreign_key: { to_table: :users }, type: :string
      t.string :image_url
      t.string :title
      t.text :metadata
      t.text :content
      t.string :status, default: "minted", null: false, comment: "minted | burned | accepted"
      t.string :display, default: "normal", null: false, comment: "normal | hidden | pinned"
      t.string :hashtags, array: true
      t.integer :value, default: 0
      t.datetime :last_value_used_at
      t.datetime :start_time
      t.datetime :end_time
      t.string :voucher_id
      t.string :domain

      t.timestamps
    end
    add_index :badges, :voucher_id
  end
end
