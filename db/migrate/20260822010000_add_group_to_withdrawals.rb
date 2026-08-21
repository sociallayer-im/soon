class AddGroupToWithdrawals < ActiveRecord::Migration[8.1]
  # WeChat revenue is pooled per GROUP, not per organizer — any manager/owner
  # of a group can withdraw its balance, and the balance itself has to be
  # tracked against the group so two different managers can't each compute
  # "my own withdrawals are zero, so the whole group balance is still mine"
  # (see design/PAYMENTS_PLAN.md discussion of the multi-manager withdrawal
  # bug this closes). user_id is kept — it still records who requested each
  # withdrawal — group_id is what balance math and locking key off of now.
  def change
    add_reference :withdrawals, :group, type: :string, null: false, foreign_key: true
  end
end
