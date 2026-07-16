class Membership < ApplicationRecord
  belongs_to :user
  # counter_cache keeps groups.memberships_count correct on every create/destroy
  # (including the owner seeded at group creation), so nothing has to remember to
  # increment/decrement it by hand.
  belongs_to :group, counter_cache: :memberships_count

  validates :user_id, uniqueness: { scope: :group_id, message: "can only join a group once" }
  validates :role, inclusion: { in: %w(member admin owner) }
end
