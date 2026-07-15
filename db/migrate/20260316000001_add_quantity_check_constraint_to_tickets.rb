class AddQuantityCheckConstraintToTickets < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :tickets, "quantity IS NULL OR quantity >= 0", name: "tickets_quantity_non_negative"
  end
end
