class AddMembershipDurationDaysToTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :tickets, :membership_duration_days, :integer, default: 30, null: false
  end
end
