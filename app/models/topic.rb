# A discussion thread inside one category.
#
# Four states, each its own nullable timestamp rather than values in a status
# column, so each fact lives in one place and records when it happened:
#
#   pinned_at  — pinned within its category
#   closed_at  — locked, takes no more replies (still readable)
#   flagged_at — hidden from everyone except its author and managers
#   deleted_at — soft deleted, hidden from everyone including its author
#
# See design/DISCUSSION_PLAN.md 1.3.
class Topic < ApplicationRecord
  include SoftDelete
  include Flaggable
  include Starrable

  MAX_CONTENT   = 64.kilobytes
  MAX_TAGS      = 10
  MAX_TAG_CHARS = 32

  # Copied from homeland: a reply stops bumping a topic that is over a month
  # old. It is anti-necroposting, and it also keeps the write hotspot on the
  # sort index confined to recent rows.
  BUMP_WINDOW = 1.month

  belongs_to :group
  belongs_to :category, counter_cache: false
  belongs_to :user
  belongs_to :last_reply, class_name: "Reply", optional: true
  belongs_to :last_reply_user, class_name: "User", optional: true
  has_many :replies, dependent: :destroy

  validates :title, presence: true, length: { maximum: 200 }
  validates :content, length: { maximum: MAX_CONTENT }, allow_blank: true
  validate  :tags_within_limits
  # group_id is denormalised off category so the group-level list needs no
  # join. That makes disagreement possible, so it is checked on every save:
  # without this, one move could relocate a topic into another community.
  validate  :category_belongs_to_group

  before_validation :default_group_from_category, on: :create
  before_create { self.last_active_mark ||= Time.now.to_i }

  after_commit :refresh_category_counts!, on: %i[create destroy]

  scope :alive,     -> { not_flagged }
  scope :pinned,    -> { where.not(pinned_at: nil) }
  scope :unpinned,  -> { where(pinned_at: nil) }
  scope :recently_active, -> { order(last_active_mark: :desc, id: :desc) }

  # Board visibility (1.2). Composed with .visible_to below; both are needed —
  # one answers "may this person see the board", the other "may they see this
  # particular topic".
  scope :in_visible_categories, ->(user) {
    where(category_id: Category.visible_to(user).select(:id))
  }

  # Flag visibility (1.3). Soft deletes are already excluded by the
  # default_scope, so this deliberately does not repeat that condition —
  # writing it in two places is how the two drift apart.
  def self.visible_to(user, manager: false)
    return all if manager
    return not_flagged if user.nil?

    not_flagged.or(where(user_id: user.id))
  end

  def closed? = closed_at.present?
  def pinned? = pinned_at.present?

  # Sole writer of the last-reply cache and replies_count. Everything that
  # creates, deletes, restores, flags or unflags a reply calls this; nothing
  # else touches those columns.
  #
  # Recomputed, never incremented — soft delete and flagging both go through
  # update_columns and fire no callbacks, so an incrementing counter drifts.
  def refresh_last_reply!
    live = replies.alive.chronological
    last = live.last
    attrs = {
      replies_count:      live.count,
      last_reply_id:      last&.id,
      last_reply_user_id: last&.user_id,
      replied_at:         last&.created_at,
      updated_at:         Time.current
    }
    # Bump only while the topic is young enough; see BUMP_WINDOW.
    attrs[:last_active_mark] = Time.now.to_i if last && created_at > BUMP_WINDOW.ago
    update_columns(attrs)
  end

  def after_flag_change! = refresh_category_counts!

  private

  def default_group_from_category
    self.group_id ||= category&.group_id
  end

  def category_belongs_to_group
    return if category.nil? || group_id.nil?

    errors.add(:category, "belongs to another group") if category.group_id != group_id
  end

  def tags_within_limits
    list = tags || []
    errors.add(:tags, "cannot have more than #{MAX_TAGS} entries") if list.size > MAX_TAGS
    return unless list.any? { |t| t.to_s.length > MAX_TAG_CHARS }

    errors.add(:tags, "each tag is at most #{MAX_TAG_CHARS} characters")
  end

  def refresh_category_counts!
    category&.refresh_topics_count!
  end
end
