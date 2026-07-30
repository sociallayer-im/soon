class AddCheckedInAtToParticipants < ActiveRecord::Migration[8.1]
  # register_time carried two incompatible meanings: RSVP stamped it as the
  # registration time, and the door-scan check_in action re-stamped it as the
  # check-in time. Anything reading it as "checked in" therefore saw every
  # registrant as checked in. Split check-in onto its own column.
  #
  # No backfill: for existing rows the two meanings are indistinguishable, and
  # treating every registrant as checked-in is exactly the bug being fixed —
  # so they start as not-checked-in, which is right for all but the handful
  # actually scanned at a door.
  def change
    add_column :participants, :checked_in_at, :datetime
  end
end
