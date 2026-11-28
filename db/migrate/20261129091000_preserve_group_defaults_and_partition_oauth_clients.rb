class PreserveGroupDefaultsAndPartitionOauthClients < ActiveRecord::Migration[8.1]
  def up
    change_column_default :groups, :discussion_enabled, false
    change_column_default :groups, :can_post_topic, "member"
    add_column :wechat_miniprogram_identities, :legacy_subject, :string
    add_index :wechat_miniprogram_identities, :legacy_subject, unique: true
  end

  def down
    remove_column :wechat_miniprogram_identities, :legacy_subject
  end
end
