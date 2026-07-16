class RemoveHandleFromUsers < ActiveRecord::Migration[8.1]
  def change
    # Users are identified by `name` now; the sails-style `handle` is dropped.
    remove_column :users, :handle, :string
  end
end
