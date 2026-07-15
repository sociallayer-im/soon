class AddBadgeForeignKeysToGroupInvites < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :group_invites, :badge_classes unless foreign_key_exists?(:group_invites, :badge_classes)
    add_foreign_key :group_invites, :badges unless foreign_key_exists?(:group_invites, :badges)
  end
end
