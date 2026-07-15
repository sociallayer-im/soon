class Comment < ApplicationRecord
  belongs_to :user
  belongs_to :badge, optional: true
  belongs_to :item, polymorphic: true, optional: true
  belongs_to :reply_parent, class_name: "Comment", optional: true
  belongs_to :edit_parent, class_name: "Comment", optional: true

  validates :comment_type, inclusion: { in: %w(checkin chat comment star feedback) }

  scope :visible, -> { where(removed: [nil, false]) }
end
