class Block < ApplicationRecord
  belongs_to :user
  belongs_to :target_user, class_name: "User"

  validate :not_self

  private

  def not_self
    errors.add(:target_user_id, "cannot block yourself") if target_user_id.present? && target_user_id == user_id
  end
end
