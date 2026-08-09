class AddAdminNotificationToMemberships < ActiveRecord::Migration[8.1]
  # Per-membership opt-out for the "someone submitted an event to your group"
  # email. Only owner/manager rows are ever read for it — a plain member has
  # nothing to be notified about — but the column lives on every membership so
  # a promotion to manager doesn't need a second write to decide the setting.
  #
  # Default true, unlike sails' column of the same name (which defaulted false
  # and therefore reached nobody until each manager opted in by hand). A group
  # admin who never touches the setting should still hear that an event is
  # waiting for them; the opt-out exists for the ones who don't want it.
  # add_column with a default backfills existing rows in one pass on PG 11+, so
  # every current owner and manager starts subscribed.
  def change
    add_column :memberships, :admin_notification, :boolean, default: true, null: false
  end
end
