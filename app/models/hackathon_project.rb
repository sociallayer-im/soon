# A submission to a hackathon — and the team that made it. There is no
# separate team entity: forming a team is creating a project with
# `recruiting` on (design/HACKATHON_MODULE.md §1.2).
#
# Flaggable but deliberately NOT SoftDelete: members of a hidden project
# would still occupy their one-per-hackathon slot with no way out. Drafts are
# hard-deleted by their owner; submitted work stays and is moderated by flag.
#
# `user_id` is the owner and the only thing permissions read. The "owner"
# role on the member row mirrors it for display and is kept in step here.
class HackathonProject < ApplicationRecord
  surf_visible_by(:hackathon_id) { Hackathon.select(:id) }

  include Flaggable

  MAX_CONTENT = 64.kilobytes
  MAX_TAGS    = 20
  LEGACY_FIELDS = { track_ids: :track_id, repo_links: :repo_url, demo_links: :demo_url, video_links: :video_url }.freeze

  before_validation :sync_legacy_fields

  belongs_to :hackathon
  belongs_to :user
  has_many :hackathon_project_members, foreign_key: :project_id, dependent: :destroy, inverse_of: :project
  has_many :members, through: :hackathon_project_members, source: :user
  has_many :hackathon_project_stars, foreign_key: :project_id, dependent: :destroy, inverse_of: :project

  validates :title, presence: true, length: { maximum: 200 }
  validates :tagline, length: { maximum: 300 }, allow_blank: true
  validates :content, length: { maximum: MAX_CONTENT }, allow_blank: true
  validates :award, length: { maximum: 100 }, allow_blank: true
  validate  :tracks_exist
  validate  :links_are_http
  validate  :tags_are_short

  scope :alive,     -> { not_flagged }
  scope :submitted, -> { where.not(submitted_at: nil) }
  scope :drafts,    -> { where(submitted_at: nil) }

  def submitted? = submitted_at.present?
  def approved?  = approved_at.present?
  def rejected?  = rejected_at.present?

  # draft | submitted | approved | rejected, derived from the timestamps.
  def status
    return "draft"    unless submitted?
    return "approved" if approved?
    return "rejected" if rejected?

    "submitted"
  end

  def owner?(u)  = !!(u && user_id == u.id)
  def member?(u) = !!(u && hackathon_project_members.exists?(user_id: u.id))
  def track      = tracks.first
  def tracks     = track_ids.filter_map { |id| hackathon.track(id) }

  def submit!
    update!(submitted_at: Time.current, recruiting: false)
    hackathon.refresh_counts!
  end

  # Back to draft. Review marks go too — they were about the withdrawn
  # version.
  def unsubmit!
    update!(submitted_at: nil, approved_at: nil, rejected_at: nil, review_note: nil)
    hackathon.refresh_counts!
  end

  def approve!(note: nil)
    update!(approved_at: Time.current, rejected_at: nil, review_note: note.presence)
  end

  def reject!(note: nil)
    update!(rejected_at: Time.current, approved_at: nil, review_note: note.presence)
  end

  # Moves ownership. Both the column and the two role rows change in one
  # transaction; the new owner must already be a member.
  def transfer_to!(new_owner)
    transaction do
      row = hackathon_project_members.find_by!(user_id: new_owner.id)
      hackathon_project_members.where(role: "owner").update_all(role: "member")
      row.update!(role: "owner")
      update!(user: new_owner)
    end
  end

  # Sole writer of both counters, recomputed rather than incremented.
  def refresh_counts!
    update_columns(stars_count: hackathon_project_stars.count,
                   members_count: hackathon_project_members.count,
                   updated_at: Time.current)
  end

  def after_flag_change!
    hackathon.refresh_counts!
  end

  private

  def sync_legacy_fields
    LEGACY_FIELDS.each do |field, legacy|
      if will_save_change_to_attribute?(legacy) && !will_save_change_to_attribute?(field)
        value = self[legacy].to_s.strip.presence
        self[field] = value ? [value, *self[field].drop(1)] : []
      end
      self[field] = self[field].map { |value| value.to_s.strip }.reject(&:empty?).uniq
      self[legacy] = self[field].first
    end
  end

  def tracks_exist
    if track_ids.any? { |id| !hackathon&.track(id) }
      errors.add(:track_ids, "must belong to this hackathon")
    end
  end

  def links_are_http
    %i[repo_links demo_links video_links].each do |field|
      next unless will_save_change_to_attribute?(field)

      (self[field] - attribute_in_database(field)).each do |link|
        uri = URI.parse(link)
        errors.add(field, "must contain HTTP or HTTPS URLs") unless uri.is_a?(URI::HTTP) && uri.host.present?
      rescue URI::InvalidURIError
        errors.add(field, "must contain HTTP or HTTPS URLs")
      end
    end
  end

  def tags_are_short
    %i[tech seeking].each do |col|
      list = Array(self[col]).map { |s| s.to_s.strip }.reject(&:empty?).uniq
      self[col] = list
      errors.add(col, "at most #{MAX_TAGS}") if list.size > MAX_TAGS
      errors.add(col, "each at most 40 characters") if list.any? { |s| s.length > 40 }
    end
  end
end
