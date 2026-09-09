class AddEligibilityToPolls < ActiveRecord::Migration[8.1]
  def change
    # Who may vote, beyond "a member of the poll's group". Both empty (the
    # default) keeps that rule. Either set widens or narrows it to: a member
    # of any listed group, or of any listed team of the poll's group.
    # Arrays rather than join tables — the same shape as tickets'
    # check_group_ids, and a poll names a handful at most.
    add_column :polls, :eligible_group_ids, :string, array: true, null: false, default: []
    add_column :polls, :eligible_team_ids,  :string, array: true, null: false, default: []
  end
end
