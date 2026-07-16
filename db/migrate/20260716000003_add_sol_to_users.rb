class AddSolToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :sol, :string
    add_index :users, :sol, unique: true
  end
end
