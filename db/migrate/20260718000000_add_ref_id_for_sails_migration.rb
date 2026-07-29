class AddRefIdForSailsMigration < ActiveRecord::Migration[8.1]
  # ref_id preserves the original integer primary key from the legacy sails/ app
  # for the records that were addressable by that id in URLs (e.g. /events/123).
  # It lets those legacy links keep resolving as an alternative lookup key.
  # Records created natively in soon/ leave ref_id NULL.
  def change
    %i[events users groups badges badge_classes vouchers].each do |table|
      add_column table, :ref_id, :string
      add_index table, :ref_id, where: "ref_id IS NOT NULL"
    end
  end
end
