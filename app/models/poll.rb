# A poll inside a group. Parallel to Topic, not a kind of it — see
# design/POLL_MODULE.md.
#
# States are nullable timestamps, as on Topic:
#   closed_at      — takes no more votes (still readable)
#   first_voted_at — starts the edit grace window (§1.2)
#   flagged_at     — hidden from everyone but its author and managers
#   deleted_at     — soft deleted
class Poll < ApplicationRecord
  include SoftDelete
  include Flaggable

  TYPES        = %w[single multiple number].freeze
  VISIBILITIES = %w[public participants secret].freeze
  RESULTS      = %w[always on_vote on_close manager_only].freeze
  MAX_OPTIONS  = 20
  MAX_CONTENT  = 64.kilobytes
  # After the first vote, options and title stay editable this long — enough
  # to fix a typo, short enough that nobody votes on one question and ends up
  # counted for another. Fixed, not per-poll: one setting fewer.
  EDIT_GRACE   = 10.minutes

  belongs_to :group
  belongs_to :user
  has_many :poll_options, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :poll
  has_many :poll_votes, dependent: :destroy

  validates :title, presence: true, length: { maximum: 200 }
  validates :content, length: { maximum: MAX_CONTENT }, allow_blank: true
  validates :poll_type,  inclusion: { in: TYPES }
  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :results,    inclusion: { in: RESULTS }
  validate  :number_range

  scope :alive, -> { not_flagged }
  scope :pending_close, -> { where(closed_at: nil).where("close_at <= ?", Time.current) }

  def self.visible_to(user, manager: false)
    return all if manager
    return not_flagged if user.nil?

    not_flagged.or(where(user_id: user.id))
  end

  def single?   = poll_type == "single"
  def multiple? = poll_type == "multiple"
  def number?   = poll_type == "number"

  # Derived at read time so a poll past its deadline reads as closed even
  # before PollAutoCloseJob has stamped closed_at.
  def closed?
    closed_at.present? || (close_at.present? && close_at <= Time.current)
  end

  def editable?
    first_voted_at.nil? || Time.current < first_voted_at + EDIT_GRACE
  end

  def voted_by?(user)
    return false if user.nil?

    poll_votes.exists?(user_id: user.id)
  end

  # The single choice / all choices / score this person made, in the shape
  # the poll type calls for. nil when they have not voted.
  def vote_of(user)
    return nil if user.nil?

    rows = poll_votes.where(user_id: user.id)
    case poll_type
    when "multiple" then rows.pluck(:option_id)
    when "number"   then rows.pick(:value)
    else                 rows.pick(:option_id)
    end
  end

  # Sole writer of every counter. Recomputed, never incremented — votes are
  # deleted and rewritten on a change of mind, which incrementing gets wrong.
  def refresh_counts!
    update_columns(votes_count: poll_votes.distinct.count(:user_id), updated_at: Time.current)
    return if number?

    counts = poll_votes.group(:option_id).count
    poll_options.each { |o| o.update_columns(votes_count: counts[o.id] || 0) }
  end

  # Aggregates for a number poll: computed on request, the population is one
  # group's members.
  def number_stats
    values = poll_votes.where.not(value: nil).order(:value).pluck(:value)
    return { count: 0, average: nil, median: nil, histogram: {} } if values.empty?

    mid = values.size / 2
    median = values.size.odd? ? values[mid] : (values[mid - 1] + values[mid]) / 2.0
    {
      count:     values.size,
      average:   (values.sum.to_f / values.size).round(2),
      median:    median,
      histogram: values.tally
    }
  end

  private

  def number_range
    if number?
      errors.add(:min_value, "is required") if min_value.nil?
      errors.add(:max_value, "is required") if max_value.nil?
      if min_value && max_value && min_value >= max_value
        errors.add(:max_value, "must be greater than min_value")
      end
    end
  end
end
