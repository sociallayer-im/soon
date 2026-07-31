class AddWechatIdentityToUsers < ActiveRecord::Migration[8.1]
  # WeChat sign-in for the CN deployment (design/WECHAT_INTEGRATION.md §1).
  #
  # Both columns, not just one. openid identifies a user within a single WeChat
  # appid; unionid is stable across every app under the same 微信开放平台 account.
  # unionid is what we key on where it exists — keying on openid alone would
  # hand the same person a second account the day a mini program or a desktop
  # QR login is added, with nothing in common to merge them by. But unionid is
  # only returned once the 服务号 is bound to an 开放平台 account, so openid has to
  # work as a fallback and both are stored.
  #
  # Partial unique indexes: NULL is the normal state — every existing user, and
  # everyone who signs in by email or wallet, has neither.
  def change
    add_column :users, :wechat_openid, :string
    add_column :users, :wechat_unionid, :string

    add_index :users, :wechat_openid, unique: true, where: "wechat_openid IS NOT NULL"
    add_index :users, :wechat_unionid, unique: true, where: "wechat_unionid IS NOT NULL"
  end
end
