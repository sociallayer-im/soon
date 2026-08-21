require "test_helper"

class Api::V1::CalendarsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = create_user
    @group = create_group(owner: @owner, timezone: "America/New_York")
  end

  test "event feed is public, returns text/calendar for a public published event" do
    event = create_event(group: @group, owner: @owner, title: "Public One",
      visibility: "normal", status: "published", timezone: "America/New_York",
      start_time: Time.utc(2026, 7, 16, 14, 0, 0), end_time: Time.utc(2026, 7, 16, 16, 0, 0))

    get "/api/v1/events/#{event.id}/calendar.ics" # no auth header
    assert_response :success
    assert_match %r{text/calendar}, response.media_type
    assert_includes response.body, "BEGIN:VCALENDAR"
    assert_includes response.body, "DTSTART;TZID=America/New_York:20260716T100000"
  end

  test "event feed hides a draft/private event" do
    draft = create_event(group: @group, owner: @owner, status: "draft", visibility: "normal")
    get "/api/v1/events/#{draft.id}/calendar.ics"
    assert_response :not_found

    private_event = create_event(group: @group, owner: @owner, status: "published", visibility: "unlisted")
    get "/api/v1/events/#{private_event.id}/calendar.ics"
    assert_response :not_found
  end

  # These two were the drift: calendar_visible? hand-copied Event.visible_to's
  # status list and left both out, so a cancelled or not-yet-approved event
  # still exported a normal ICS entry.
  test "event feed hides a cancelled event" do
    cancelled = create_event(group: @group, owner: @owner, status: "cancelled", visibility: "normal")
    get "/api/v1/events/#{cancelled.id}/calendar.ics"
    assert_response :not_found
  end

  test "event feed hides an event awaiting manager approval" do
    pending = create_event(group: @group, owner: @owner, status: "pending", visibility: "normal")
    get "/api/v1/events/#{pending.id}/calendar.ics"
    assert_response :not_found
  end

  test "event feed 404s for an unknown id" do
    get "/api/v1/events/nope/calendar.ics"
    assert_response :not_found
  end

  test "group feed lists published public events as a named subscribable calendar" do
    create_event(group: @group, owner: @owner, title: "Shown", status: "published", visibility: "normal",
      start_time: Time.utc(2026, 7, 16, 14, 0, 0), end_time: Time.utc(2026, 7, 16, 15, 0, 0))
    create_event(group: @group, owner: @owner, title: "Hidden Draft", status: "draft", visibility: "normal",
      start_time: Time.utc(2026, 7, 17, 14, 0, 0), end_time: Time.utc(2026, 7, 17, 15, 0, 0))

    get "/api/v1/groups/#{@group.id}/calendar.ics" # public, no auth
    assert_response :success
    assert_match %r{text/calendar}, response.media_type
    assert_includes response.body, "METHOD:PUBLISH"
    assert_includes response.body, "X-WR-CALNAME"
    assert_equal 1, response.body.scan("BEGIN:VEVENT").size
    assert_includes response.body, "SUMMARY:Shown"
  end

  test "group feed resolves by slug" do
    owner = create_user
    group = create_group(owner: owner, name: "sluggy-group")
    create_event(group: group, owner: owner, status: "published")

    get "/api/v1/groups/sluggy-group/calendar.ics"
    assert_response :success
    assert_match "BEGIN:VCALENDAR", response.body
  end
end
