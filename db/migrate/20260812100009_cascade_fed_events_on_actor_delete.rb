class CascadeFedEventsOnActorDelete < ActiveRecord::Migration[8.1]
  # When a remote actor deletes itself (or we purge it), the events we mirrored
  # on its behalf have to go too: nothing can ever update them again, and the
  # existing foreign key would block the delete outright.
  def up
    remove_foreign_key :fed_events, :fed_actors
    add_foreign_key :fed_events, :fed_actors, on_delete: :cascade
  end

  def down
    remove_foreign_key :fed_events, :fed_actors
    add_foreign_key :fed_events, :fed_actors
  end
end
