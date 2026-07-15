class FixRecurringIdInEvents < ActiveRecord::Migration[8.1]
  def change
    add_reference :events, :recurring, null: true, foreign_key: true, type: :string unless column_exists?(:events, :recurring_id)
  end
end
