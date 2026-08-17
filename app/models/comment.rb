class Comment < ApplicationRecord
  belongs_to :user
  belongs_to :badge, optional: true
  belongs_to :item, polymorphic: true, optional: true
  belongs_to :reply_parent, class_name: "Comment", optional: true
  belongs_to :edit_parent, class_name: "Comment", optional: true

  validates :comment_type, inclusion: { in: %w[checkin chat comment star feedback] }
  # item_type reaches this model straight from a request parameter and is then
  # used for polymorphic lookups and as a subquery discriminator, so it needs a
  # whitelist rather than accepting any string at all.
  #
  # Guarded on the column actually changing, the same way HandleName guards its
  # format rule: rows predating this list were migrated from sails and may hold
  # values not in it, and validating unconditionally would freeze every one of
  # them out of ordinary updates like `removed: true`.
  #
  # The list is the set this codebase actually attaches comments to — Event and
  # Group from the frontend, BadgeClass from the feedback mail path — plus
  # Topic. It is deliberately not "every model": the point is that an arbitrary
  # string cannot be stored here.
  ITEM_TYPES = %w[Event Group BadgeClass Topic Reply].freeze
  validates :item_type, inclusion: { in: ITEM_TYPES }, allow_nil: true,
    if: :will_save_change_to_item_type?

  scope :visible, -> { where(removed: [ nil, false ]) }
end
