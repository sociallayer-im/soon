class AddGroupCoordinates < ActiveRecord::Migration[8.0]
  def change
    add_column :groups, :latitude, :decimal, precision: 10, scale: 6
    add_column :groups, :longitude, :decimal, precision: 10, scale: 6
  end
end
