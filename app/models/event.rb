class Event < ApplicationRecord
  belongs_to :group, inverse_of: :events
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

  # An event with no explicit timezone inherits its group's. Fixed at creation:
  # a later change to the group's zone leaves existing events untouched.
  before_validation :inherit_group_timezone, on: :create

  # Events a user is allowed to see in a listing: public & not draft/pending/
  # archived/cancelled to everyone (pending = awaiting manager approval via
  # #approve — see EventsController#pending_approval — must stay unlisted
  # until then, same as a draft; cancelled matches sails' behavior — a
  # cancelled event drops out of browse listings entirely), plus anything they
  # own or manage (group admin/owner) — an organizer still sees their own
  # cancelled event (with the "Cancelled" badge — see CardEvent) so they know
  # it's cancelled rather than it silently vanishing for them too. Callers
  # still scope by group membership on top of this.
  scope :visible_to, ->(user) {
    managed = Membership.where(user_id: user&.id, role: %w[manager owner]).select(:group_id)
    where(
      "(events.visibility = 'public' AND events.status NOT IN ('draft', 'pending', 'archived', 'cancelled')) " \
      "OR events.owner_id = :uid OR events.group_id IN (:managed)",
      uid: user&.id, managed: managed
    )
  }

  # The event's display zone: its own `timezone`, else the group's, else UTC.
  # Always a valid IANA/Rails zone — free-text junk falls back to UTC so callers
  # can safely `in_time_zone(event_timezone)` without rescuing.
  def event_timezone
    candidate = timezone.presence || group&.timezone.presence
    candidate && ActiveSupport::TimeZone[candidate] ? candidate : "UTC"
  end

  # Wall-clock start/end in the event's own zone (for emails, .ics, display).
  def local_start = start_time&.in_time_zone(event_timezone)
  def local_end   = end_time&.in_time_zone(event_timezone)

  def cancelled? = status == "cancelled"

  # A calendar (.ics) for this event. Delegates to EventCalendar so VTIMEZONE,
  # TZID, SEQUENCE and iTIP METHOD are handled in one place.
  def to_ics(method: "PUBLISH", attendee: nil)
    EventCalendar.for_event(self, method: method, attendee: attendee)
  end

  # Human-readable place: physical place name, else the meeting/external link.
  def location_text
    place&.name.presence || meeting_url.presence || external_url.presence
  end

  private

  def inherit_group_timezone
    self.timezone = group&.timezone if timezone.blank?
  end

  def end_time_after_start_time
    return unless start_time && end_time
    errors.add(:end_time, "must be after start time") if end_time <= start_time
  end
end
