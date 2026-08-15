require "icalendar/tzinfo"

# Builds RFC 5545 iCalendar (.ics) output for events — the single source of
# truth for calendar generation, used by both the lifecycle emails and the
# public subscription feeds.
#
# Correctness properties:
#   * Times are emitted in the event's own zone with a TZID + a full VTIMEZONE
#     (DST rules included), so Apple Calendar / Google / Outlook show the right
#     wall-clock time for viewers in any zone. UTC events use Z-suffixed times.
#   * UID is stable per event, so an update or cancellation REPLACES the entry a
#     recipient already added (rather than duplicating it).
#   * SEQUENCE is derived from updated_at and increases on every edit, and
#     DTSTAMP is the (UTC) last-modified time — both required for clients to
#     accept an update/cancel over a previously-imported copy.
#   * iTIP METHOD distinguishes an invite (REQUEST), a cancellation (CANCEL),
#     and a subscription feed (PUBLISH).
class EventCalendar
  ORGANIZER_EMAIL = ENV.fetch("MAIL_FROM_ADDRESS", "send@app.sola.day").freeze
  # Apple Calendar / Outlook poll subscriptions at (roughly) this cadence.
  REFRESH = "PT1H".freeze

  # One event as a standalone calendar. method: REQUEST | CANCEL | PUBLISH.
  # attendee: an email to mark as the invitee (for REQUEST/CANCEL invites).
  def self.for_event(event, method: "PUBLISH", attendee: nil)
    build([event], method: method, attendee: attendee)
  end

  # Many events as a subscribable feed (always PUBLISH).
  def self.feed(events, name:)
    build(events.to_a, method: "PUBLISH", calendar_name: name)
  end

  def self.build(events, method:, attendee: nil, calendar_name: nil)
    cal = Icalendar::Calendar.new
    cal.prodid    = "-//#{ApplicationMailer::BRAND_NAME}//soon//EN"
    cal.ip_method = method
    cal.append_custom_property("X-WR-CALNAME", calendar_name) if calendar_name.present?
    cal.append_custom_property("X-PUBLISHED-TTL", REFRESH)
    cal.append_custom_property("REFRESH-INTERVAL;VALUE=DURATION", REFRESH)

    seen_zones = {}
    events.each do |event|
      tzid = event.event_timezone
      add_vtimezone(cal, tzid, event.start_time, seen_zones)
      cal.event { |e| populate(e, event, tzid, method, attendee) }
    end
    cal.to_ical
  end

  # --- internals ---

  # Emit a VTIMEZONE once per non-UTC zone. (UTC needs none — we use Z times.)
  def self.add_vtimezone(cal, tzid, reference_time, seen_zones)
    return if tzid == "UTC" || seen_zones[tzid]

    seen_zones[tzid] = true
    tz = TZInfo::Timezone.get(tzid)
    cal.add_timezone(tz.ical_timezone(reference_time.in_time_zone(tzid)))
  rescue TZInfo::InvalidTimezoneIdentifier
    # event_timezone already guards this, but stay defensive for feeds.
    nil
  end

  def self.populate(entry, event, tzid, method, attendee)
    cancelled = method == "CANCEL" || event.cancelled?
    starts = zoned_value(event.start_time, tzid)
    ends   = zoned_value(event.end_time || event.start_time + 1.hour, tzid)

    entry.uid         = uid_for(event)
    entry.dtstamp     = utc_value(event.updated_at)
    entry.dtstart     = starts
    entry.dtend       = ends
    entry.summary     = event.title
    entry.description = description_for(event)
    entry.location    = event.location_text if event.location_text.present?
    entry.url         = event_url(event)
    entry.sequence    = event.updated_at.to_i
    entry.status      = cancelled ? "CANCELLED" : "CONFIRMED"
    entry.organizer   = Icalendar::Values::CalAddress.new(
      "mailto:#{ORGANIZER_EMAIL}", cn: ApplicationMailer::BRAND_NAME
    )

    return if attendee.blank?

    entry.append_attendee Icalendar::Values::CalAddress.new(
      "mailto:#{attendee}", cn: attendee, rsvp: "FALSE",
      partstat: cancelled ? "DECLINED" : "ACCEPTED"
    )
  end

  # Local time carrying a TZID (non-UTC), or a Z-suffixed UTC value.
  def self.zoned_value(time, tzid)
    if tzid == "UTC"
      Icalendar::Values::DateTime.new(time.utc, "tzid" => "UTC")
    else
      Icalendar::Values::DateTime.new(time.in_time_zone(tzid), "tzid" => tzid)
    end
  end

  def self.utc_value(time)
    Icalendar::Values::DateTime.new(time.utc, "tzid" => "UTC")
  end

  # An iCalendar UID must never change for the life of an event (RFC 5545 3.8.4.7)
  # — a subscribed client treats a new UID as a NEW event and keeps the old one,
  # so every event in every subscribed calendar would silently double.
  #
  # This used to be derived from WEB_URL, which made the UID hostage to a
  # frontend domain change. It is pinned to app.sola.day because that is what
  # every UID already in someone's calendar says; it is an opaque identifier
  # here, not a URL, and nothing dereferences it. Do not "fix" it to sola.day.
  ICAL_UID_HOST = "app.sola.day".freeze

  def self.uid_for(event)
    "event-#{event.id}@#{ICAL_UID_HOST}"
  end

  def self.event_url(event)
    "#{ApplicationMailer::WEB_URL}/event/detail/#{event.id}"
  end

  # Markdown data-URI images (some event descriptions have base64-embedded
  # images pasted directly into the rich-text editor, occasionally multiple
  # MB each) render as nothing useful in a calendar app's DESCRIPTION field,
  # so strip them rather than balloon every .ics download/feed refresh.
  DATA_URI_IMAGE = /!\[[^\]]*\]\(data:[^)]+\)/.freeze

  # Calendar apps show DESCRIPTION as a short popover preview, not a reader —
  # the event URL is always appended right after, so a full multi-KB writeup
  # (some run 20-30KB) buys nothing but bandwidth. Same cap for single-event
  # invites and feeds: there's no reason an invite email needs more text than
  # a subscription feed does when both link to the full page.
  DESCRIPTION_TRUNCATE_LENGTH = 500

  def self.description_for(event)
    parts = []
    if event.content.present?
      text = event.content.gsub(DATA_URI_IMAGE, "").strip
      parts << text.truncate(DESCRIPTION_TRUNCATE_LENGTH, omission: "…")
    end
    parts << event_url(event)
    parts.join("\n\n")
  end

  private_class_method :build, :add_vtimezone, :populate, :zoned_value,
    :utc_value, :uid_for, :description_for
end
