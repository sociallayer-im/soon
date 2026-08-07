class Venue < ApplicationRecord
  belongs_to :group
  belongs_to :owner, class_name: "User"
  belongs_to :place, optional: true
  has_many :events, dependent: :nullify
  has_many :availabilities, as: :item, dependent: :destroy

  # Deliberately NOT unique. Names are labels, not identifiers — every lookup
  # goes through the TSID. Uniqueness used to be global, which meant a
  # soft-deleted venue (archived: true, invisible in the UI) kept blocking its
  # own name on recreate, and two groups could never both have a "Main Hall".
  validates :name, presence: true
  validates :capacity, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :end_date, comparison: { greater_than: :start_date }, if: -> { start_date.present? && end_date.present? }

  # Canonical availability + overlap check for booking an event into this venue.
  # Returns [available?, message]. Semantics (mirrors sails/ and CLAUDE.md):
  #   - outside the venue's overall start_date/end_date window (if set) → not available
  #   - overlaps any other non-cancelled event in this venue → not available
  #   - a date override (Availability with `day == the event's date`) takes priority
  #     over weekly slots; the event must fall entirely within one of its intervals
  #   - otherwise a weekly slot (Availability with matching `day_of_week`) applies
  #   - if weekly slots are configured but none match this weekday → closed
  #   - a venue with no Availability records at all is open 7×24
  def check_availability(event_start, event_end, timezone = nil, event_id = nil)
    tz = timezone.presence || group&.timezone.presence || "UTC"
    start_time = event_start.in_time_zone(tz)
    end_time   = event_end.in_time_zone(tz)

    if start_date && start_time.to_date < start_date
      return [false, "venue is not available before #{start_date}"]
    end
    if end_date && end_time.to_date > end_date
      return [false, "venue is not available after #{end_date}"]
    end

    overlap = events.where("start_time < ? AND end_time > ?", event_end, event_start)
                    .where.not(status: "cancelled")
    overlap = overlap.where.not(id: event_id) if event_id
    return [false, "venue is already booked for this time"] if overlap.exists?

    override = availabilities.find_by(day: start_time.to_date)
    weekly   = availabilities.find_by(day_of_week: start_time.strftime("%A").downcase)
    start_secs = start_time.seconds_since_midnight.to_i
    end_secs   = end_time.seconds_since_midnight.to_i

    if override
      return [false, "venue is closed at this time"] unless within_intervals?(override.intervals, start_secs, end_secs)
    elsif weekly
      return [false, "venue is closed at this time"] unless within_intervals?(weekly.intervals, start_secs, end_secs)
    elsif availabilities.where.not(day_of_week: nil).exists?
      return [false, "venue is closed on this day"]
    end

    [true, "ok"]
  end

  private

  def within_intervals?(intervals, start_secs, end_secs)
    # end_secs < start_secs means the event runs past midnight; slot windows are
    # single-day, so such an event can't fit inside one.
    return false if end_secs < start_secs

    Array(intervals).any? do |from, to|
      next false unless from && to
      seconds_of(from) <= start_secs && seconds_of(to) >= end_secs
    end
  end

  def seconds_of(hhmm)
    hours, minutes = hhmm.to_s.split(":").map(&:to_i)
    (hours.to_i * 3600) + (minutes.to_i * 60)
  end
end
