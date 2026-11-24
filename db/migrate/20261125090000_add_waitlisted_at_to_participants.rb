class AddWaitlistedAtToParticipants < ActiveRecord::Migration[8.1]
  def change
    add_column :participants, :waitlisted_at, :datetime
    add_index :participants, [:event_id, :waitlisted_at, :id],
      where: "status = 'waitlisted'", name: "index_participants_on_waitlist"
    change_column_comment :participants, :status,
      from: "attending | pending | declined | maybe | cancelled — see Participant",
      to: "attending | pending | waitlisted | declined | maybe | cancelled — see Participant"
  end
end
