class Follow < ApplicationRecord
  belongs_to :user

  STATUSES = %w[active inactive].freeze
  TARGET_TYPES = %w[User Group].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :target_type, inclusion: { in: TARGET_TYPES }
  validates :target_id, presence: true
  validate :target_exists
  validate :not_self

  scope :active, -> { where(status: "active") }

  private

  def target_exists
    return if target_id.blank?

    exists = case target_type
    when "User" then User.exists?(id: target_id)
    when "Group" then Group.exists?(id: target_id)
    else false
    end
    errors.add(:target_id, "not found") unless exists
  end

  def not_self
    errors.add(:target_id, "cannot follow yourself") if target_type == "User" && target_id == user_id
  end
end
