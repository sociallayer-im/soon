class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :group

  validates :user_id, uniqueness: { scope: :group_id, message: "can only join a group once" }
  validates :role, inclusion: { in: %w(member admin owner) }
end
