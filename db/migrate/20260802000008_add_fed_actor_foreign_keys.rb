class AddFedActorForeignKeys < ActiveRecord::Migration[8.1]
  # comments.fed_actor_id and participants.fed_actor_id had no constraint, so
  # removing a cached remote actor left rows pointing at nothing: the comment
  # then rendered with no author at all, neither local nor remote. Found in the
  # lab after re-fetching an actor.
  #
  # Cascade rather than nullify: both models treat the actor as the author's
  # identity (Participant even validates that exactly one of user/fed_actor is
  # set), so a row that lost it is not a valid record — if an actor is ever
  # purged, its content goes with it. Normal moderation sets
  # fed_actors.blocked_at and deletes nothing.
  def up
    execute <<~SQL
      DELETE FROM comments c
       WHERE c.fed_actor_id IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM fed_actors a WHERE a.id = c.fed_actor_id);
      DELETE FROM participants p
       WHERE p.fed_actor_id IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM fed_actors a WHERE a.id = p.fed_actor_id);
    SQL

    add_foreign_key :comments, :fed_actors, on_delete: :cascade
    add_foreign_key :participants, :fed_actors, on_delete: :cascade
  end

  def down
    remove_foreign_key :comments, :fed_actors
    remove_foreign_key :participants, :fed_actors
  end
end
