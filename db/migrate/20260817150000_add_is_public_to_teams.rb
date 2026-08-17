class AddIsPublicToTeams < ActiveRecord::Migration[8.1]
  def change
    # Private by default. A team is an internal grouping until someone decides
    # it is a public identity — the reverse default would publish every
    # existing team the moment it is created, and a team name can be as
    # sensitive as its membership ("moderation watchlist").
    #
    # Named is_public to match tracks.is_private rather than the bare word,
    # which reads ambiguously next to Ruby's own `public`.
    add_column :teams, :is_public, :boolean, null: false, default: false
  end
end
