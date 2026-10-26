class Report < ApplicationRecord
  belongs_to :user
  belongs_to :resolved_by, class_name: "User", optional: true

  STATUSES = %w[open resolved dismissed].freeze

  validates :reason, :target_type, presence: true
  validates :status, inclusion: { in: STATUSES }
end
