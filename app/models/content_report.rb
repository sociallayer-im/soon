class ContentReport < ApplicationRecord
  belongs_to :reporter, class_name: "User"
  belongs_to :reviewer, class_name: "User", optional: true
  validates :target_type, inclusion: { in: %w[Topic Event] }
  validates :reason, presence: true, length: { maximum: 500 }
  validates :status, inclusion: { in: %w[pending reviewed] }
end
