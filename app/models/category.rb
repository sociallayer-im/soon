# A discussion board, belonging to one group.
#
# NOT a site-wide taxonomy. The bare name `Category` is taken by this feature
# (design/DISCUSSION_PLAN.md 1.0); anything that later needs to categorise
# events or badges has to be EventCategory / BadgeCategory. `group_id` is
# null: false precisely so this cannot quietly become a general-purpose table.
#
# Flat, with no parent_id — ordering is `sort`, exactly as homeland's nodes.
class Category < ApplicationRecord
  VISIBILITIES = %w[public member manager team].freeze

  belongs_to :group
  has_many :category_teams, dependent: :destroy
  has_many :teams, through: :category_teams
  has_many :topics, dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 100 }
  validates :slug, presence: true, format: { with: /\A[a-z0-9][a-z0-9-]*\z/,
    message: "must be lowercase letters, digits and hyphens" },
    length: { maximum: 50 },
    uniqueness: { scope: :group_id, case_sensitive: false }
  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :summary, length: { maximum: 500 }, allow_blank: true

  scope :sorted, -> { order(sort: :desc, created_at: :asc) }
  scope :listed, -> { where(archived: false) }

  # The categories `user` may see inside `group`. Everything that reads topics
  # goes through this — see Topic.in_visible_categories.
  #
  # Written as one relation rather than a Ruby filter so it can compose into a
  # subquery: the topic list must not load every category to decide.
  def self.visible_to(user, group: nil)
    scope = group ? where(group_id: group.id) : all
    return scope if user&.platform_admin?
    return scope.where(visibility: "public") if user.nil?

    managed = user.memberships.where(role: %w[manager owner]).select(:group_id)
    joined  = user.memberships.select(:group_id)
    # A board restricted to a team names the team, not the people — so the
    # restriction has a meaning ("the volunteers") and is maintained in one
    # place instead of once per board.
    teamed  = CategoryTeam.where(team_id: TeamMembership.where(user_id: user.id).select(:team_id))
                          .select(:category_id)

    # Membership in the group itself, never in its parent. An earlier version
    # let a parent group's managers see a child's manager-only board on the
    # grounds that they manage their children — which is not what this
    # codebase decided: GroupPolicy narrowed a parent manager's power over a
    # child to promoting and demoting managers, and nothing else (2026-07-29,
    # recorded there as deliberate). Granting read access here would have made
    # this the one private surface that rule did not cover, and moderation
    # would still have refused them, so they could read a board they could not
    # act on.
    # A manager sees every board in their own group, whatever its visibility.
    # Two reasons, and the second is the one that forced it: moderation of a
    # team board is impossible if its managers cannot open it, and a board
    # whose only team has been deleted matches no other branch here — it would
    # keep its topics and become unreachable by the very people who could
    # re-point or archive it. This is not a confidentiality boundary either
    # way: a manager can already PATCH any board's visibility.
    scope.where(group_id: managed)
         .or(scope.where(visibility: "public"))
         .or(scope.where(visibility: "member", group_id: joined))
         .or(scope.where(visibility: "team", id: teamed))
  end

  def visible_to?(user)
    self.class.visible_to(user).exists?(id: id)
  end

  def private? = visibility != "public"

  # Sole writer of topics_count. Recomputed rather than incremented, for the
  # reason in design/DISCUSSION_PLAN.md 1.1: soft delete and flagging both go
  # through update_columns, which fires no callbacks, so a counter_cache would
  # drift. Counts live rows only, so the number matches the list beside it.
  def refresh_topics_count!
    update_columns(topics_count: topics.not_flagged.count, updated_at: Time.current)
  end
end
