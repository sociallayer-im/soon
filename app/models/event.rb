class Event < ApplicationRecord
  belongs_to :group
  belongs_to :owner, class_name: "User"
  belongs_to :place, optional: true
  belongs_to :track, optional: true
  belongs_to :venue, optional: true
  belongs_to :recurring, optional: true
  belongs_to :form, optional: true
  has_many :participants, dependent: :destroy
  has_many :participant_users, through: :participants, source: :user
  has_many :event_roles, dependent: :destroy
  has_many :tickets, dependent: :destroy
  has_many :ticket_items, dependent: :destroy
  has_many :coupons, dependent: :destroy

  accepts_nested_attributes_for :coupons, allow_destroy: true

  STATUSES = %w(draft pending published archived closed cancelled).freeze
  VISIBILITIES = %w(public private).freeze

  validates :title, presence: true
  validates :start_time, presence: true
  validates :end_time, presence: true
  validates :status, inclusion: { in: STATUSES }, allow_nil: true
  validates :visibility, inclusion: { in: VISIBILITIES }, allow_nil: true
  validate :end_time_after_start_time

  # Events a user is allowed to see in a listing: public & not draft/archived to
  # everyone, plus anything they own or manage (group admin/owner). Callers still
  # scope by group membership on top of this.
  scope :visible_to, ->(user) {
    managed = Membership.where(user_id: user&.id, role: %w[admin owner]).select(:group_id)
    where(
      "(events.visibility = 'public' AND events.status NOT IN ('draft', 'archived')) " \
      "OR events.owner_id = :uid OR events.group_id IN (:managed)",
      uid: user&.id, managed: managed
    )
  }

  # A calendar invite (.ics) for this event, attached to lifecycle emails so the
  # recipient can add it to their calendar. `cancelled:` emits STATUS:CANCELLED
  # (and METHOD:CANCEL) so a calendar client removes a previously-added event.
  def to_ics(cancelled: false)
    cal = Icalendar::Calendar.new
    cal.prodid = "-//#{ApplicationMailer::BRAND_NAME}//EN"
    cal.ip_method = cancelled ? "CANCEL" : "PUBLISH"
    cal.event do |e|
      e.uid         = "event-#{id}@#{ApplicationMailer::WEB_URL.sub(%r{https?://}, "")}"
      e.dtstart     = Icalendar::Values::DateTime.new(start_time.utc)
      e.dtend       = Icalendar::Values::DateTime.new((end_time || start_time).utc)
      e.summary     = title
      e.description = content if content.present?
      e.location    = location_text if location_text.present?
      e.url         = "#{ApplicationMailer::WEB_URL}/event/detail/#{id}"
      e.status      = cancelled ? "CANCELLED" : "CONFIRMED"
    end
    cal.to_ical
  end

  # Human-readable place: physical place name, else the meeting/external link.
  def location_text
    place&.name.presence || meeting_url.presence || external_url.presence
  end

  private

  def end_time_after_start_time
    return unless start_time && end_time
    errors.add(:end_time, "must be after start time") if end_time <= start_time
  end
end
