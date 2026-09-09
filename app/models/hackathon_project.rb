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
  include Flaggable

  MAX_CONTENT = 64.kilobytes
  MAX_TAGS    = 20

  belongs_to :hackathon
  belongs_to :user
  has_many :hackathon_project_members, foreign_key: :project_id, dependent: :destroy, inverse_of: :project
  has_many :members, through: :hackathon_project_members, source: :user
  has_many :hackathon_project_stars, foreign_key: :project_id, dependent: :destroy, inverse_of: :project

  validates :title, presence: true, length: { maximum: 200 }
  validates :tagline, length: { maximum: 300 }, allow_blank: true
  validates :content, length: { maximum: MAX_CONTENT }, allow_blank: true
  validates :award, length: { maximum: 100 }, allow_blank: true
  validate  :track_exists
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
  def track      = hackathon.track(track_id)

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

  def track_exists
    return if track_id.blank?
    return if hackathon&.track(track_id)

    errors.add(:track_id, "is not a track of this hackathon")
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
