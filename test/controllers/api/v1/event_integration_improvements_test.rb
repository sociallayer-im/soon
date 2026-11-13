require "test_helper"

class Api::V1::EventIntegrationImprovementsTest < ActionDispatch::IntegrationTest
  def setup
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner, status: "published", tags: ["摄影", "旅行"])
  end

  test "tag suggestions only contain public discoverable event tags and exact filtering works" do
    create_event(group: @group, owner: @owner, status: "draft", tags: ["摄影私密"])
    get "/api/v1/events/tag_suggestions", params: { q: "摄影" }
    assert_response :success
    assert_includes json_response["data"], "摄影"
    assert_not_includes json_response["data"], "摄影私密"
    get "/api/v1/events", params: { tag: "摄影", browse_all: true }
    assert_response :success
    assert_includes json_response["data"].map { |event| event["id"] }, @event.id
    get "/api/v1/events", params: { tag: "摄", browse_all: true }
    assert_not_includes json_response["data"].map { |event| event["id"] }, @event.id
  end

  test "ticket total cannot be set below occupied inventory" do
    ticket = create_ticket(event: @event, quantity: 3)
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    assert_response :success
    patch "/api/v1/events/#{@event.id}/tickets/#{ticket.id}", params: { ticket: { total_quantity: 0 } }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    patch "/api/v1/events/#{@event.id}/tickets/#{ticket.id}", params: { ticket: { total_quantity: 4 } }, headers: auth_headers(@owner)
    assert_response :success
    assert_equal 3, ticket.reload.quantity
  end

  test "group coordinates are validated and exposed" do
    @group.update!(latitude: 31.2, longitude: 121.5)
    get "/api/v1/groups/#{@group.id}"
    assert_response :success
    assert_equal 31.2, json_response["latitude"].to_f
    assert_equal 121.5, json_response["longitude"].to_f
    assert_not @group.update(latitude: 91)
  end
  test "unlimited ticket still respects event capacity and cancellation releases seat" do
    @event.update!(max_participant: 1)
    ticket = create_ticket(event: @event, quantity: nil)
    first = create_user
    second = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(first)
    assert_response :success
    item = TicketItem.find(json_response["ticket_item"]["id"])
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(second)
    assert_response :unprocessable_entity
    item.cancel(actor: first)
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(second)
    assert_response :success
  end

  test "comments with the same timestamp have stable ordering across pages" do
    timestamp = Time.current.change(usec: 0)
    comments = 3.times.map { |i| Comment.create!(user: @owner, item: @group, comment_type: "comment", content: "comment #{i}", created_at: timestamp) }
    ids = []
    3.times do |index|
      get "/api/v1/comments", params: { item_type: "Group", item_id: @group.id, comment_type: "comment", sort: "newest", limit: 1, page: index + 1 }
      assert_response :success
      ids << json_response["data"].first["id"]
    end
    assert_equal comments.map(&:id).sort.reverse, ids
  end

  test "cursor comments do not repeat when a newer comment is added" do
    timestamp = 2.minutes.ago.change(usec: 0)
    originals = 3.times.map { |i| Comment.create!(user: @owner, item: @group, comment_type: "comment", content: "old #{i}", created_at: timestamp) }
    params = {item_type: "Group", item_id: @group.id, comment_type: "comment", limit: 1, cursor: "start"}
    get "/api/v1/comments", params: params
    assert_response :success
    ids = [json_response["data"].first["id"]]
    cursor = json_response["meta"]["next_cursor"]
    Comment.create!(user: @owner, item: @group, comment_type: "comment", content: "new")
    2.times do
      get "/api/v1/comments", params: params.merge(cursor: cursor)
      assert_response :success
      ids << json_response["data"].first["id"]
      cursor = json_response["meta"]["next_cursor"]
    end
    assert_equal originals.map(&:id).sort.reverse, ids
    assert_nil cursor
    get "/api/v1/comments", params: params.merge(cursor: "invalid")
    assert_response :unprocessable_entity
  end

end
