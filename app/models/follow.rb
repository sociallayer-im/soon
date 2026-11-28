class Follow < ApplicationRecord
  default_scope { where.not(target_type: "Group").or(where(target_id: SurfGroupVisibility.group_ids)) if SurfGroupVisibility.group_ids }

  TARGET_TYPES = %w[User Group].freeze
  STATUSES = %w[active pending declined].freeze

  belongs_to :user
  belongs_to :target, polymorphic: true

  validates :target_type, inclusion: { in: TARGET_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :target_id, uniqueness: { scope: [ :user_id, :target_type ] }
  validate :not_a_self_follow

  private

  def not_a_self_follow
    return unless target_type == "User" && user_id.present? && target_id == user_id

    errors.add(:target_id, "cannot follow yourself")
  end
end
