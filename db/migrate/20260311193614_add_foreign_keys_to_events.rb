class AddForeignKeysToEvents < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :events, :places unless foreign_key_exists?(:events, :places)
    add_foreign_key :events, :tracks unless foreign_key_exists?(:events, :tracks)
    add_foreign_key :events, :venues unless foreign_key_exists?(:events, :venues)
  end
end
