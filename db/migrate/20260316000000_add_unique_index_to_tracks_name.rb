class AddUniqueIndexToTracksName < ActiveRecord::Migration[8.1]
  def change
    add_index :tracks, :name, unique: true
  end
end
