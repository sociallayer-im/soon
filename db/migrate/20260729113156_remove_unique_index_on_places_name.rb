class RemoveUniqueIndexOnPlacesName < ActiveRecord::Migration[8.1]
  def change
    # A global name-unique index was wrong: two genuinely different real-world
    # locations can share the same text name (a hotel chain's "Patio" in two
    # different cities, two different venues both called "Community Room"),
    # and forcing them into one Place row corrupts data instead of protecting
    # it. PlacesController#create already does its own soft find-by-name
    # dedup on the write path; that's sufficient without a hard DB constraint.
    remove_index :places, :name
    add_index :places, :name
  end
end
