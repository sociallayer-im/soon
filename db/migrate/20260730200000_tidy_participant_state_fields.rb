class TidyParticipantStateFields < ActiveRecord::Migration[8.1]
  def up
    # Soft delete gets a timestamp like the other lifecycle marks
    # (registered_at, checked_in_at) instead of only a status string.
    add_column :participants, :cancelled_at, :datetime
    execute "UPDATE participants SET cancelled_at = updated_at WHERE status = 'cancelled'"

    # Write-only column: rsvp stamped it and nothing ever read it. It also
    # can't be right — a participant may hold several orders for different
    # ticket types, which ticket_items already records per order.
    remove_column :participants, :ticket_id

    change_column_comment :participants, :status,
      from: "attending | declined | maybe",
      to: "attending | pending | declined | maybe | cancelled — see Participant"
    change_column_comment :participants, :payment_status, from: nil,
      to: "derived summary of this participant's ticket_items; see Participant#refresh_payment_status!"

    # Every seat-counting query filters on this.
    add_index :participants, [ :event_id, :status ]
  end

  def down
    remove_index :participants, [ :event_id, :status ]
    change_column_comment :participants, :payment_status, from: nil, to: nil
    change_column_comment :participants, :status, from: nil, to: "attending | declined | maybe"
    add_column :participants, :ticket_id, :string
    remove_column :participants, :cancelled_at
  end
end
