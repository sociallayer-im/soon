class AddDataToPlaces < ActiveRecord::Migration[8.1]
  def change
    add_column :places, :data, :jsonb, default: {}
  end
end
