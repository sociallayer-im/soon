class AddCheckGroupIdsToTickets < ActiveRecord::Migration[8.1]
  def change
    # Membership-gated tickets: only a member of one of these groups may claim.
    # NULL/empty = no gate. Distinct from group_id, which is the ticket's OWNER.
    add_column :tickets, :check_group_ids, :string, array: true
  end
end
