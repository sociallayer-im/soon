class AddAttemptsToAuthCodes < ActiveRecord::Migration[8.1]
  def change
    add_column :auth_codes, :attempts, :integer, default: 0, null: false
    add_index :auth_codes, [:recipient, :context, :used_at]
  end
end
