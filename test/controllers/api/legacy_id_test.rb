require "test_helper"

# Links minted by the legacy sails backend carry its integer primary key
# (/event/detail/11399) and are still in circulation — bookmarks, shared
# messages, search results, calendar subscriptions. They must keep resolving
# after the cutover via ref_id. See design/MIGRATION_PLAN.md §12.
class Api::LegacyIdTest < ActionDispatch::IntegrationTest
  setup do
    @user  = create_user
    @group = create_group(owner: @user)
  end

  test "an event is reachable by its legacy integer id" do
    event = create_event(group: @group, owner: @user, ref_id: "11399")

    get "/api/v1/events/11399", headers: auth_headers(@user)

    assert_response :success
    assert_equal event.id, json_response["id"]
  end

  test "the TSID still works — the fallback is additive" do
    event = create_event(group: @group, owner: @user, ref_id: "11399")

    get "/api/v1/events/#{event.id}", headers: auth_headers(@user)

    assert_response :success
    assert_equal event.id, json_response["id"]
  end

  test "an unknown legacy id 404s rather than 500ing" do
    get "/api/v1/events/999999999", headers: auth_headers(@user)
    assert_response :not_found
  end

  test "a non-numeric unknown identifier never touches the ref_id lookup" do
    # A missing TSID must 404 on its own; digits-only is the only shape that
    # can be a legacy id, so anything else must not fall through.
    create_event(group: @group, owner: @user, ref_id: "11399")

    get "/api/v1/events/not-a-real-tsid", headers: auth_headers(@user)

    assert_response :not_found
  end

  test "records without a ref_id are not matched by a numeric identifier" do
    # Post-migration records have ref_id nil. A numeric lookup must not find
    # them via find_by(ref_id: nil).
    create_event(group: @group, owner: @user, ref_id: nil)

    get "/api/v1/events/12345", headers: auth_headers(@user)

    assert_response :not_found
  end

  test "an event's calendar feed is reachable by legacy id" do
    create_event(group: @group, owner: @user, ref_id: "11399",
      visibility: "normal", status: "published")

    get "/api/v1/events/11399/calendar.ics"

    assert_response :success
    assert_match(/BEGIN:VCALENDAR/, response.body)
  end

  test "badges, badge classes and vouchers resolve by legacy id too" do
    badge_class = BadgeClass.create!(name: "bc#{unique_suffix}", title: "BC",
      creator: @user, group: @group, ref_id: "2001")
    voucher = Voucher.create!(badge_class: badge_class, sender: @user,
      counter: 1, ref_id: "3001")
    badge = Badge.create!(badge_class: badge_class, creator: @user,
      owner: @user, title: "B", ref_id: "4001")

    get "/api/v1/badge_classes/2001"
    assert_response :success
    assert_equal badge_class.id, json_response["id"]

    get "/api/v1/vouchers/3001"
    assert_response :success
    assert_equal voucher.id, json_response["id"]

    get "/api/v1/badges/4001"
    assert_response :success
    assert_equal badge.id, json_response["id"]
  end
end
