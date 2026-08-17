class AddStarsCountToReplies < ActiveRecord::Migration[8.1]
  def change
    # Stars live in `comments`, not in an association, so a reply cannot see
    # its own — the count has to be denormalised here and refreshed by
    # Reply#refresh_stars_count!, its only writer.
    add_column :replies, :stars_count, :integer, null: false, default: 0
  end
end
