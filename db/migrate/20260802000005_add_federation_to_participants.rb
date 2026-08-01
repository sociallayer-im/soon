class AddFederationToParticipants < ActiveRecord::Migration[8.1]
  # Remote participants reuse the participants table so capacity checks,
  # approval flow and counts stay one implementation
  # (design/FEDERATION_PLAN.md §2.5/§2.7). user_id becomes nullable: a remote
  # attendee has a fed_actor instead.
  def change
    add_column :participants, :fed_actor_id, :string
    add_column :participants, :fed_join_uri, :string

    change_column_null :participants, :user_id, true

    add_index :participants, [:fed_actor_id, :event_id], unique: true,
              where: "fed_actor_id IS NOT NULL"
    add_index :participants, :fed_join_uri, unique: true, where: "fed_join_uri IS NOT NULL"
  end
end
