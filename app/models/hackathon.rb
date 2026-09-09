# A hackathon inside a group. Parallel to Poll, not a kind of Event — see
# design/HACKATHON_MODULE.md.
#
# Registration is not modelled here at all: `event` is an ordinary Event whose
# participants, form, tickets and check-in do that job. This side only knows
# the event's id; Event knows nothing about hackathons (the FK is ON DELETE
# SET NULL so Event needs no association).
#
# States are nullable timestamps and derived predicates, as on Poll: `status`
# is the one thing a person decides (published or not); whether submissions
# are open is computed from the window, never stored.
class Hackathon < ApplicationRecord
  include SoftDelete
  include Flaggable

  STATUSES       = %w[draft published].freeze
  VISIBILITIES   = %w[always after_submit after_review].freeze
  SUBMIT_TIERS   = %w[participant member everyone].freeze
  MAX_TRACKS     = 20
  MAX_CONTENT    = 64.kilobytes
  TRACK_ID_CHARS = ("a".."z").to_a + ("0".."9").to_a

  belongs_to :group
  belongs_to :user
  belongs_to :event, optional: true
  has_many :hackathon_projects, dependent: :destroy
  has_many :hackathon_project_members, dependent: :destroy

  validates :title, presence: true, length: { maximum: 200 }
  validates :tagline, length: { maximum: 300 }, allow_blank: true
  validates :content, length: { maximum: MAX_CONTENT }, allow_blank: true
  validates :status, inclusion: { in: STATUSES }
  validates :projects_visibility, inclusion: { in: VISIBILITIES }
  validates :can_submit_project, inclusion: { in: SUBMIT_TIERS }
  validate  :event_belongs_to_group
  validate  :participant_tier_needs_event
  validate  :after_submit_needs_close
  validate  :window_is_ordered
  validate  :tracks_well_formed

  scope :alive, -> { not_flagged }

  def self.visible_to(user, manager: false)
    return all if manager
    return not_flagged.where(status: "published") if user.nil?

    not_flagged.where(status: "published").or(where(user_id: user.id))
  end

  def published? = status == "published"

  def submission_open?
    published? &&
      (submit_open_at.nil?  || submit_open_at  <= Time.current) &&
      (submit_close_at.nil? || Time.current < submit_close_at)
  end

  def submission_closed?
    submit_close_at.present? && submit_close_at <= Time.current
  end

  def track(id)
    return nil if id.blank?

    tracks.find { |t| t["id"] == id }
  end

  # Sole writer of projects_count. Recomputed, never incremented — a project
  # can be withdrawn or hard-deleted, and increments get both wrong.
  def refresh_counts!
    update_columns(projects_count: hackathon_projects.where.not(submitted_at: nil).count,
                   updated_at: Time.current)
  end

  # Replace the track list wholesale. Incoming rows carry an id to keep an
  # existing track or none to mint one; a track absent from the list is
  # removed — refused if any project still names it, since silently
  # un-tracking someone's submission is not this method's decision to make.
  def replace_tracks!(rows)
    rows = Array(rows).map { |r| r.respond_to?(:to_h) ? r.to_h.stringify_keys : {} }
    rows = rows.reject { |r| r["title"].to_s.strip.empty? }
    raise ActiveRecord::RecordInvalid, tap { |h| h.errors.add(:tracks, "at most #{MAX_TRACKS}") } if rows.size > MAX_TRACKS

    existing = tracks.map { |t| t["id"] }
    keep     = rows.map { |r| r["id"] }.compact
    removed  = existing - keep
    if removed.any?
      n = hackathon_projects.where(track_id: removed).count
      if n.positive?
        raise ActiveRecord::RecordInvalid, tap { |h|
          h.errors.add(:tracks, "#{n} project(s) still use a removed track")
        }
      end
    end

    self.tracks = rows.map do |r|
      id = r["id"].presence
      id = mint_track_id if id.nil? || !existing.include?(id)
      { "id" => id, "title" => r["title"].to_s.strip,
        "description" => r["description"].to_s.presence, "color" => r["color"].to_s.presence }.compact
    end
    save!
  end

  private

  def mint_track_id
    loop do
      id = Array.new(6) { TRACK_ID_CHARS.sample }.join
      return id unless tracks.any? { |t| t["id"] == id }
    end
  end

  def event_belongs_to_group
    return if event.nil? || group.nil?

    errors.add(:event_id, "must be an event of this group") unless event.group_id == group_id
  end

  # A tier that reads participants needs an event to read them from. The DB
  # can null event_id later (event deleted); HackathonPolicy re-checks then.
  def participant_tier_needs_event
    return unless can_submit_project == "participant" && event_id.blank?

    errors.add(:can_submit_project, "participant tier needs a registration event")
  end

  # after_submit with no close would mean "never public".
  def after_submit_needs_close
    return unless projects_visibility == "after_submit" && submit_close_at.blank?

    errors.add(:submit_close_at, "is required when projects open after the submission deadline")
  end

  def window_is_ordered
    return unless submit_open_at && submit_close_at && submit_open_at >= submit_close_at

    errors.add(:submit_close_at, "must be after submit_open_at")
  end

  def tracks_well_formed
    unless tracks.is_a?(Array) && tracks.all? { |t| t.is_a?(Hash) && t["id"].present? && t["title"].present? }
      errors.add(:tracks, "must be a list of {id, title}")
      return
    end
    ids = tracks.map { |t| t["id"] }
    errors.add(:tracks, "ids must be unique") if ids.uniq.size != ids.size
  end
end
