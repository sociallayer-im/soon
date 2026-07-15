class CreateGroupInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :group_invites, id: :string do |t|
      t.string :sender_id
      t.string :receiver_id
      t.references :group, null: false, foreign_key: true, type: :string
      t.string :message
      t.datetime :expires_at
      t.string :badge_class_id
      t.string :badge_id
      t.string :role, default: "member", comment: "member | manager | owner"
      t.string :status, default: "sending", null: false, comment: "sending | requesting | accepted | cancelled | revoked"
      t.string :receiver_address_type, default: "id", comment: "id | email | code"
      t.string :receiver_address
      t.string :ticket_id

      t.timestamps
    end
    add_index :group_invites, :sender_id
    add_index :group_invites, :receiver_id
    add_foreign_key :group_invites, :users, column: :sender_id
    add_foreign_key :group_invites, :users, column: :receiver_id
  end
end
