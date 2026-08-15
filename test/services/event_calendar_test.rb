require "test_helper"

class EventCalendarTest < ActiveSupport::TestCase
  setup do
    @owner = create_user
    @group = create_group(owner: @owner, timezone: "America/New_York")
    # 14:00 UTC == 10:00 EDT on 2026-07-16.
    @event = create_event(group: @group, owner: @owner, title: "Launch",
      timezone: "America/New_York",
      start_time: Time.utc(2026, 7, 16, 14, 0, 0), end_time: Time.utc(2026, 7, 16, 16, 0, 0))
  end

  test "emits the event in its own zone with a VTIMEZONE and TZID-qualified times" do
    ics = EventCalendar.for_event(@event)

    assert_includes ics, "BEGIN:VTIMEZONE"
    assert_includes ics, "TZID:America/New_York"
    # 14:00 UTC projected to 10:00 local, tagged with the zone (not floating/UTC).
    assert_includes ics, "DTSTART;TZID=America/New_York:20260716T100000"
    assert_includes ics, "DTEND;TZID=America/New_York:20260716T120000"
    assert_includes ics, "SUMMARY:Launch"
  end

  test "UID is stable and DTSTAMP is UTC (Z-suffixed)" do
    ics = EventCalendar.for_event(@event)

    assert_includes ics, "UID:event-#{@event.id}@#{EventCalendar::ICAL_UID_HOST}"
    assert_match(/DTSTAMP:\d{8}T\d{6}Z/, ics)
  end

  # The UID used to be derived from WEB_URL, so the 2026-08-15 move of the
  # frontend to sola.day would have rewritten the UID of every event already
  # sitting in someone's subscribed calendar — which a client reads as a brand
  # new event while keeping the old one, i.e. the whole calendar doubles. This
  # pins the decoupling: the link URLs follow WEB_URL, the identifier does not.
  test "UID does not follow WEB_URL" do
    ics = EventCalendar.for_event(@event)
    web_host = ApplicationMailer::WEB_URL.sub(%r{\Ahttps?://}, "")

    assert_includes ics, "URL;VALUE=URI:#{ApplicationMailer::WEB_URL}/event/detail/#{@event.id}"
    refute_includes ics, "UID:event-#{@event.id}@#{web_host}"
    assert_equal "app.sola.day", EventCalendar::ICAL_UID_HOST
  end

  test "SEQUENCE increases after an edit" do
    first = sequence_of(EventCalendar.for_event(@event))
    travel_to(1.minute.from_now) { @event.update!(title: "Renamed") }
    second = sequence_of(EventCalendar.for_event(@event))

    assert_operator second, :>, first
  end

  test "REQUEST invite carries METHOD and the attendee" do
    ics = unfold(EventCalendar.for_event(@event, method: "REQUEST", attendee: "guest@test.com"))

    assert_includes ics, "METHOD:REQUEST"
    assert_includes ics, "ATTENDEE"
    assert_includes ics, "mailto:guest@test.com"
    assert_includes ics, "STATUS:CONFIRMED"
  end

  test "CANCEL method marks the event cancelled" do
    ics = EventCalendar.for_event(@event, method: "CANCEL", attendee: "guest@test.com")

    assert_includes ics, "METHOD:CANCEL"
    assert_includes ics, "STATUS:CANCELLED"
  end

  test "a UTC event uses Z-suffixed times and no VTIMEZONE" do
    utc_event = create_event(group: create_group(owner: @owner), owner: @owner, title: "UTC",
      timezone: "UTC", start_time: Time.utc(2026, 7, 16, 9, 0, 0), end_time: Time.utc(2026, 7, 16, 10, 0, 0))
    ics = EventCalendar.for_event(utc_event)

    assert_not_includes ics, "BEGIN:VTIMEZONE"
    # Canonical UTC form: Z-suffixed, no redundant TZID param.
    assert_includes ics, "DTSTART:20260716T090000Z"
  end

  test "an invalid free-text timezone falls back to UTC instead of raising" do
    bad = create_event(group: create_group(owner: @owner), owner: @owner, title: "Bad TZ",
      timezone: "Not/AZone", start_time: Time.utc(2026, 7, 16, 9, 0, 0), end_time: Time.utc(2026, 7, 16, 10, 0, 0))

    assert_equal "UTC", bad.event_timezone
    ics = EventCalendar.for_event(bad)
    assert_not_includes ics, "BEGIN:VTIMEZONE"
    assert_includes ics, "DTSTART:20260716T090000Z"
  end

  test "feed includes every event and a calendar name" do
    create_event(group: @group, owner: @owner, title: "Second",
      timezone: "America/New_York", start_time: Time.utc(2026, 7, 20, 14, 0, 0),
      end_time: Time.utc(2026, 7, 20, 15, 0, 0))
    ics = EventCalendar.feed(@group.events.order(:start_time), name: "My Feed")

    assert_includes ics, "METHOD:PUBLISH"
    assert_includes ics, "X-WR-CALNAME:My Feed"
    assert_equal 2, ics.scan("BEGIN:VEVENT").size
  end

  test "embedded base64 images are stripped from the description, not just truncated away" do
    tiny = "See you there!"
    huge_image = "![](data:image/png;base64,#{"A" * 2000})"
    event = create_event(group: @group, owner: @owner, title: "With image",
      content: "#{tiny}\n\n#{huge_image}")

    ics = unfold(EventCalendar.for_event(event))

    assert_includes ics, tiny
    assert_not_includes ics, "base64"
    assert_not_includes ics, "data:image"
  end

  test "a long description is truncated and the event URL still follows it" do
    event = create_event(group: @group, owner: @owner, title: "Long",
      content: "A" * 2000)

    ics = unfold(EventCalendar.for_event(event))
    description = ics[/DESCRIPTION:(.*?)(?:\r?\n[A-Z]+[:;])/m, 1]

    assert_operator description.length, :<, 2000
    assert_includes description, "…"
    assert_operator description.scan("A").size, :<=, EventCalendar::DESCRIPTION_TRUNCATE_LENGTH
    assert_includes ics, "URL;VALUE=URI:#{ApplicationMailer::WEB_URL}/event/detail/#{event.id}"
  end

  test "a short description is left untouched" do
    event = create_event(group: @group, owner: @owner, title: "Short", content: "Quick note.")
    ics = unfold(EventCalendar.for_event(event))

    assert_includes ics, "Quick note."
    assert_not_includes ics, "…"
  end

  private

  def sequence_of(ics)
    ics[/SEQUENCE:(\d+)/, 1].to_i
  end

  # Reverse RFC 5545 line folding ("\r\n " continuations) so long values
  # (e.g. a folded ATTENDEE) can be matched as a single string.
  def unfold(ics)
    ics.gsub(/\r\n[ \t]/, "")
  end
end
