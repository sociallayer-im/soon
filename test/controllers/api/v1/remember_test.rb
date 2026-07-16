require "test_helper"

# The remember flow: create voucher (auto-join) → others join via QR →
# creator mints one identical badge per joiner → voucher consumed.
class RememberTest < ActionDispatch::IntegrationTest
  def remember_badge_class(creator: nil)
    create_badge_class(creator: creator || create_user, badge_type: "remember")
  end

  test "meta exposes the remember badge class and joiner threshold" do
    get "/api/v1/remember/meta"
    assert_response :success
    assert_empty json_response["types"]

    bc = remember_badge_class
    get "/api/v1/remember/meta"
    assert_equal bc.id, json_response["types"].first["badge_class_id"]
    assert_equal 2, json_response["types"].first["count"]
  end

  test "create makes a remember voucher and auto-joins the creator" do
    creator = create_user
    bc = remember_badge_class

    post "/api/v1/remember", params: { badge_class_id: bc.id, message: "gm" },
      headers: auth_headers(creator)
    assert_response :created
    assert_equal "remember", json_response["voucher"]["strategy"]
    assert_equal [creator.id], json_response["activities"].map { |a| a["initiator"]["id"] }

    # A non-remember badge class is rejected.
    plain = create_badge_class(creator: creator)
    post "/api/v1/remember", params: { badge_class_id: plain.id }, headers: auth_headers(creator)
    assert_response :unprocessable_entity
  end

  test "join is idempotent, show is public, cancel leaves" do
    creator = create_user
    joiner = create_user
    bc = remember_badge_class
    post "/api/v1/remember", params: { badge_class_id: bc.id }, headers: auth_headers(creator)
    voucher_id = json_response["voucher"]["id"]

    2.times do
      post "/api/v1/remember/#{voucher_id}/join", headers: auth_headers(joiner)
      assert_response :success
    end

    get "/api/v1/remember/#{voucher_id}" # anonymous poll
    assert_response :success
    assert_equal [creator.id, joiner.id], json_response["activities"].map { |a| a["initiator"]["id"] }

    post "/api/v1/remember/#{voucher_id}/cancel", headers: auth_headers(joiner)
    get "/api/v1/remember/#{voucher_id}"
    assert_equal [creator.id], json_response["activities"].map { |a| a["initiator"]["id"] }
  end

  test "mint is creator-only, needs enough joiners, mints one badge each, and consumes the voucher" do
    creator = create_user
    joiner = create_user
    bc = remember_badge_class
    post "/api/v1/remember", params: { badge_class_id: bc.id, message: "zurich night" },
      headers: auth_headers(creator)
    voucher_id = json_response["voucher"]["id"]

    # Not enough members yet (only the creator).
    post "/api/v1/remember/#{voucher_id}/mint", headers: auth_headers(creator)
    assert_response :unprocessable_entity

    post "/api/v1/remember/#{voucher_id}/join", headers: auth_headers(joiner)

    # Only the creator can mint.
    post "/api/v1/remember/#{voucher_id}/mint", headers: auth_headers(joiner)
    assert_response :forbidden

    post "/api/v1/remember/#{voucher_id}/mint", headers: auth_headers(creator)
    assert_response :success
    owners = json_response["badges"].map { |b| b["owner"]["id"] }
    assert_equal [creator.id, joiner.id].sort, owners.sort
    assert_equal 0, json_response["voucher"]["counter"]

    # Consumed: a second mint fails, and the poll shows counter 0.
    post "/api/v1/remember/#{voucher_id}/mint", headers: auth_headers(creator)
    assert_response :unprocessable_entity
  end

  test "related_groups maps users to popup-city groups they attended" do
    owner = create_user
    attendee = create_user
    popup = create_group(owner: owner, start_date: Date.new(2026, 9, 1), location: "Chiang Mai")
    plain = create_group(owner: owner)
    create_participant(event: create_event(group: popup, owner: owner), user: attendee)
    create_participant(event: create_event(group: plain, owner: owner), user: attendee)

    get "/api/v1/remember/related_groups", params: { user_ids: attendee.id }
    assert_response :success
    entry = json_response["group_data"][attendee.id]
    assert_equal [popup.id], entry["groups"].map { |g| g["id"] }
  end
end
