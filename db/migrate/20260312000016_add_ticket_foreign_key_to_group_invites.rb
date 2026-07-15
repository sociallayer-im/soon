class AddTicketForeignKeyToGroupInvites < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :group_invites, :tickets unless foreign_key_exists?(:group_invites, :tickets)
  end
end
