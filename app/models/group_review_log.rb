class GroupReviewLog < ApplicationRecord
  belongs_to :group
  belongs_to :reviewer, class_name: "User", optional: true
  validates :decision, inclusion: {in: %w[approved rejected resubmitted]}
end
