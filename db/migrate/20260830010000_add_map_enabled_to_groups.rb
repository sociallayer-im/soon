class AddMapEnabledToGroups < ActiveRecord::Migration[8.1]
  def change
    # Opt-in, same reasoning as discussion_enabled: Google Maps rendering is
    # the resource-heavy piece of the map feature (see seastar-app's lazy-load
    # rework), so turning it on for every existing group the moment the
    # deployment-wide NEXT_PUBLIC_ENABLE_GOOGLE_MAP flag flips would undo the
    # point of gating it per group.
    add_column :groups, :map_enabled, :boolean, null: false, default: false
  end
end
