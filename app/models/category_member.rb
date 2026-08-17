# One row per person allowed into a `visibility: "invited"` category.
#
# Only that tier has rows here. The member/manager tiers read `memberships`
# instead: materialising them would be a copy that has to be re-synced on every
# join and leave, and would drift the first time something forgot.
class CategoryMember < ApplicationRecord
  belongs_to :category
  belongs_to :user

  validates :user_id, uniqueness: { scope: :category_id }
end
