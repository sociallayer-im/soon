class AddTicketFieldsToParticipants < ActiveRecord::Migration[8.1]
  def change
    add_column :participants, :payment_status, :string
    add_column :participants, :voucher_id, :string
    add_column :participants, :badge_id, :string
    add_column :participants, :ticket_id, :string
    add_column :participants, :message, :string
    add_column :participants, :register_time, :datetime

    add_foreign_key :participants, :vouchers
    add_foreign_key :participants, :badges
    add_foreign_key :participants, :tickets
  end
end
