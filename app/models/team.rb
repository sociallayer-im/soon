# A named subset of a group's members.
#
# Team is to a group's members what Track is to its events: a grouping that is
# also an identity, and a dimension other features can hang off later. It
# confers no permissions of its own — the one place a team affects visibility
# is a discussion board that names it, and there the board is doing the
# referring.
class Team < ApplicationRecord
  belongs_to :group
  has_many :team_memberships, dependent: :destroy
  has_many :users, through: :team_memberships
  # Deleting a team un-groups people; it does not delete them, and nothing is
  # orphaned. A board that named this team simply stops naming it — which is
  # why the UI warns before the delete rather than the model refusing it.
  has_many :category_teams, dependent: :destroy

  validates :name, presence: true, length: { maximum: 60 }
  validates :slug, presence: true, length: { maximum: 40 },
    format: { with: /\A[a-z0-9][a-z0-9-]*\z/,
              message: "must be lowercase letters, digits and hyphens" },
    uniqueness: { scope: :group_id, case_sensitive: false }
  validates :description, length: { maximum: 300 }, allow_blank: true

  scope :sorted, -> { order(sort: :desc, created_at: :asc) }
  # Teams whose badge may be shown to someone outside the group. The roster
  # itself is public, so this is what decides whether a team name travels with
  # it. See MembershipBlueprint.
  scope :publicly_visible, -> { where(is_public: true) }
  scope :listed, -> { where(archived: false) }

  # Sole writer, recomputed rather than incremented — the same rule the other
  # counters in this codebase follow, and for the same reason: rows can leave
  # by paths that fire no callbacks.
  def refresh_members_count!
    update_columns(members_count: team_memberships.count, updated_at: Time.current)
  end
end
