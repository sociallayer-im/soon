class RemoveVenueNameUniqueness < ActiveRecord::Migration[8.1]
  # Venue names carried a global UNIQUE index, which was wrong on two counts:
  #
  #   1. Removing a venue is a soft delete (archived: true), so the archived row
  #      kept holding its name — recreating a venue with the same name failed
  #      with "Name has already been taken" against a row the user could no
  #      longer see anywhere in the UI.
  #   2. Venue names are not identifiers. Two groups both having a "Main Hall",
  #      or one group running a "Room A" in two buildings, are ordinary — every
  #      lookup goes through the TSID (Venue.find_by(id:)), and the schedule
  #      filter matches on venue.id, so nothing depends on the name being unique.
  #
  # No replacement index: nothing queries venues by name.
  def change
    remove_index :venues, :name, unique: true, name: "index_venues_on_name"
  end
end
