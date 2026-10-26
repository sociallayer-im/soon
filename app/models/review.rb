class Review < ApplicationRecord
  belongs_to :campaign
  belongs_to :decided_by, class_name: "User", optional: true

  SCOPES = %w[creator].freeze
  STATUSES = %w[pending approved changes_requested superseded].freeze

  validates :scope, inclusion: { in: SCOPES }
  validates :status, inclusion: { in: STATUSES }
  validates :round, numericality: { only_integer: true, greater_than: 0 }
end
