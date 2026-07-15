require "test_helper"

class Api::V1::ActivitiesControllerTest < ActionDispatch::IntegrationTest
  test "index returns only activities where current user is the receiver" do
    user = create_user
    other = create_user
    initiator = create_user

    mine = create_activity(initiator: initiator, receiver: user, action: "badge/transfer")
    create_activity(initiator: initiator, receiver: other, action: "badge/transfer")
    create_activity(initiator: initiator, receiver: nil, action: "voucher/create") # no receiver at all

    get "/api/v1/activities", headers: auth_headers(user)
    assert_response :success
    ids = json_response["data"].map { |a| a["id"] }
    assert_equal [mine.id], ids
  end

  test "index requires authentication" do
    get "/api/v1/activities"
    assert_response :unauthorized
  end

  test "index is ordered created_at desc and paginated" do
    user = create_user
    initiator = create_user
    older = create_activity(initiator: initiator, receiver: user, action: "badge/transfer")
    older.update_column(:created_at, 2.days.ago)
    newer = create_activity(initiator: initiator, receiver: user, action: "badge/burn")
    newer.update_column(:created_at, 1.hour.ago)

    get "/api/v1/activities", headers: auth_headers(user)
    assert_response :success
    ids = json_response["data"].map { |a| a["id"] }
    assert_equal [newer.id, older.id], ids
    assert json_response["meta"].key?("page")
    assert json_response["meta"].key?("total")
  end

  test "index blueprint exposes action, item, has_read, payload, initiator" do
    user = create_user
    initiator = create_user
    badge_class = create_badge_class(creator: initiator)
    badge = create_badge(badge_class: badge_class, creator: initiator, owner: initiator)
    activity = create_activity(initiator: initiator, receiver: user, action: "badge/transfer",
      item: badge, payload: { note: "hi" })

    get "/api/v1/activities", headers: auth_headers(user)
    row = json_response["data"].find { |a| a["id"] == activity.id }
    assert_equal "badge/transfer", row["action"]
    assert_equal "Badge", row["item_type"]
    assert_equal badge.id, row["item_id"]
    assert_equal false, row["has_read"]
    assert_equal({ "note" => "hi" }, row["payload"])
    assert_equal initiator.id, row["initiator"]["id"]
  end

  test "mark_read sets has_read true for the caller's own activities" do
    user = create_user
    initiator = create_user
    a1 = create_activity(initiator: initiator, receiver: user, action: "badge/transfer")
    a2 = create_activity(initiator: initiator, receiver: user, action: "badge/burn")

    post "/api/v1/activities/mark_read", params: { ids: [a1.id, a2.id] }, headers: auth_headers(user)
    assert_response :success
    assert_equal "ok", json_response["result"]
    assert a1.reload.has_read
    assert a2.reload.has_read
  end

  test "mark_read is forbidden if any id belongs to another user's activity" do
    user = create_user
    other = create_user
    initiator = create_user
    mine = create_activity(initiator: initiator, receiver: user, action: "badge/transfer")
    not_mine = create_activity(initiator: initiator, receiver: other, action: "badge/burn")

    post "/api/v1/activities/mark_read", params: { ids: [mine.id, not_mine.id] }, headers: auth_headers(user)
    assert_response :forbidden
    assert_not mine.reload.has_read
    assert_not not_mine.reload.has_read
  end

  test "mark_read with an empty/unmatched id list is a no-op success" do
    user = create_user
    post "/api/v1/activities/mark_read", params: { ids: [] }, headers: auth_headers(user)
    assert_response :success
  end
end
