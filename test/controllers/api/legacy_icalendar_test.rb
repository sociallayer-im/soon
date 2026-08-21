require "test_helper"

# /group/icalendar is the calendar-feed URL the legacy sails backend served.
# It lives inside subscribers' calendar apps and can never be updated, so it
# has to keep working. See design/MIGRATION_PLAN.md §12.
class Api::LegacyIcalendarTest < ActionDispatch::IntegrationTest
  setup do
    @user  = create_user
    @group = create_group(owner: @user, ref_id: "498")
    @event = create_event(group: @group, owner: @user,
      title: "Public Meetup", visibility: "normal", status: "published")
  end

  test "resolves by group_name, the form subscription URLs actually use" do
    get "/group/icalendar", params: { group_name: @group.name }

    assert_response :success
    assert_equal "text/calendar; charset=utf-8", response.media_type + "; charset=" + response.charset
    assert_match(/BEGIN:VCALENDAR/, response.body)
    assert_match(/Public Meetup/, response.body)
  end

  test "resolves by the legacy integer group_id" do
    get "/group/icalendar", params: { group_id: "498" }

    assert_response :success
    assert_match(/Public Meetup/, response.body)
  end

  test "serves byte-identical content to the /api/v1 feed" do
    get "/group/icalendar", params: { group_name: @group.name }
    legacy = response.body

    get "/api/v1/groups/#{@group.name}/calendar.ics"
    assert_equal response.body, legacy
  end

  test "needs no authentication — calendar clients cannot send a JWT" do
    get "/group/icalendar", params: { group_name: @group.name }
    assert_response :success
  end

  test "draft and private events stay out of the feed" do
    create_event(group: @group, owner: @user, title: "Secret Draft",
      visibility: "normal", status: "draft")
    create_event(group: @group, owner: @user, title: "Private Thing",
      visibility: "unlisted", status: "published")

    get "/group/icalendar", params: { group_name: @group.name }

    assert_response :success
    assert_no_match(/Secret Draft/, response.body)
    assert_no_match(/Private Thing/, response.body)
  end

  test "an unknown group 404s instead of 500ing" do
    get "/group/icalendar", params: { group_name: "no-such-group" }
    assert_response :not_found
  end

  test "no identifier at all 404s" do
    get "/group/icalendar"
    assert_response :not_found
  end

  test "groups are also reachable by legacy integer id on the /api/v1 route" do
    get "/api/v1/groups/498/calendar.ics"

    assert_response :success
    assert_match(/Public Meetup/, response.body)
  end

  test "a post-migration group is not matched by a numeric identifier" do
    create_group(owner: @user, ref_id: nil)

    get "/group/icalendar", params: { group_id: "999999" }

    assert_response :not_found
  end
end
