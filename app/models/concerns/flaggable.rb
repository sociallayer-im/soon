# Hiding something without deleting it.
#
# A flagged record stays visible to its own author, together with the reason —
# a post that vanishes with no explanation is the usual starting point of a
# moderation dispute. It stays visible to managers too, or they could not
# review or undo their own decision. Everyone else cannot see it at all.
#
# This is a different thing from soft delete, and the two are independent: a
# topic can be flagged and later deleted. That is exactly why neither is a
# value in a shared status column.
module Flaggable
  extend ActiveSupport::Concern

  included do
    belongs_to :flagged_by, class_name: "User", optional: true

    scope :not_flagged, -> { where(flagged_at: nil) }
  end

  def flagged? = flagged_at.present?

  def flag!(by:, reason: nil)
    update_columns(flagged_at: Time.current, flagged_by_id: by&.id,
                   flag_reason: reason.presence, updated_at: Time.current)
    after_flag_change!
    true
  end

  def unflag!
    update_columns(flagged_at: nil, flagged_by_id: nil, flag_reason: nil,
                   updated_at: Time.current)
    after_flag_change!
    true
  end

  # Counters count live rows only, so flagging changes them. Overridden by
  # models that own a counter; a no-op otherwise.
  def after_flag_change!; end
end
