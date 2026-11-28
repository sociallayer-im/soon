class CreateWechatMiniprogramIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :wechat_miniprogram_identities do |t|
      t.references :user, type: :string, null: false, foreign_key: { on_delete: :cascade }
      t.string :appid, null: false
      t.string :openid, null: false
      t.timestamps
    end
    add_index :wechat_miniprogram_identities, [:appid, :openid], unique: true
    add_index :wechat_miniprogram_identities, [:appid, :user_id], unique: true
  end
end
