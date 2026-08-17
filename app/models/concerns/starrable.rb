# Stars, which live in `comments` (comment_type: "star") rather than in an
# association on the starred record.
#
# That is why a count has to be denormalised onto the record and refreshed
# explicitly: nothing here can see its own stars. As everywhere else in this
# feature the count is recomputed rather than incremented, and this method is
# its only writer.
module Starrable
  extend ActiveSupport::Concern

  def star_scope
    Comment.where(item_type: self.class.name, item_id: id, comment_type: "star",
                  removed: [ nil, false ])
  end

  def refresh_stars_count!
    update_columns(stars_count: star_scope.count, updated_at: Time.current)
  end

  def starred_by?(user)
    return false if user.nil?

    star_scope.exists?(user_id: user.id)
  end
end
