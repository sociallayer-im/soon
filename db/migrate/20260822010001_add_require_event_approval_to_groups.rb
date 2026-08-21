class AddRequireEventApprovalToGroups < ActiveRecord::Migration[8.1]
  def change
    add_column :groups, :require_event_approval, :boolean, default: false, null: false
  end
end
