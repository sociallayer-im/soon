require "test_helper"

# Chunk F of the frontend migration: public map (markers) with authorization
# fixes, public comment reads, and profile-page event tabs (owner/attendee
# filters on the public events list).
class MapAndProfileTabsTest < ActionDispatch::IntegrationTest
  test "markers are publicly browsable by group slug and category" do
    owner = create_user
    group = create_group(owner: owner)
    place = create_place
    cafe = create_marker(group: group, place: place, owner: owner, category: "cafe")
    create_marker(group: group, place: place, owner: owner, category: "coworking")

    get "/api/v1/markers", params: { group_id: group.name, category: "cafe" }
    assert_response :success
    assert_equal [cafe.id], json_response["data"].map { |m| m["id"] }

    # Anonymous without a group filter is rejected (no "all markers" firehose).
    get "/api/v1/markers"
    assert_response :unprocessable_entity
  end

  test "marker create requires group membership; update/destroy require owner or manager" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    place = create_place
    marker = create_marker(group: group, place: place, owner: owner)

    post "/api/v1/markers", params: { marker: { group_id: group.id, place_id: place.id, title: "X" } },
      headers: auth_headers(outsider)
    assert_response :forbidden

    patch "/api/v1/markers/#{marker.id}", params: { marker: { title: "Hacked" } },
      headers: auth_headers(outsider)
    assert_response :forbidden
    assert_not_equal "Hacked", marker.reload.title

    delete "/api/v1/markers/#{marker.id}", headers: auth_headers(outsider)
    assert_response :forbidden

    patch "/api/v1/markers/#{marker.id}", params: { marker: { title: "Renamed" } },
      headers: auth_headers(owner)
    assert_response :success
  end

  test "comments are publicly readable" do
    user = create_user
    Comment.create!(user: user, comment_type: "comment", item_type: "Event", item_id: "x", content: "hi")

    get "/api/v1/comments", params: { comment_type: "comment", item_type: "Event", item_id: "x" }
    assert_response :success
    assert_equal ["hi"], json_response["data"].map { |c| c["content"] }
  end

  test "events list filters by owner and attendee for profile tabs" do
    host = create_user
    attendee = create_user
    group = create_group(owner: host)
    hosted = create_event(group: group, owner: host, status: "published")
    create_participant(event: hosted, user: attendee)
    create_event(group: group, owner: create_user_in(group), status: "published")

    get "/api/v1/events", params: { owner_id: host.name }
    assert_equal [hosted.id], json_response["data"].map { |e| e["id"] }

    get "/api/v1/events", params: { attendee_id: attendee.name }
    assert_equal [hosted.id], json_response["data"].map { |e| e["id"] }

    # An authenticated viewer's own-groups default must not narrow profile tabs.
    stranger = create_user
    get "/api/v1/events", params: { owner_id: host.name }, headers: auth_headers(stranger)
    assert_equal [hosted.id], json_response["data"].map { |e| e["id"] }
  end

  test "group send_email broadcasts to members, supports test mode, manager-only" do
    owner = create_user(email: "owner@test.com")
    member = create_user(email: "member@test.com")
    outsider = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group)

    post "/api/v1/groups/#{group.id}/send_email",
      params: { subject: "Hello", content: "News" }, headers: auth_headers(outsider)
    assert_response :forbidden

    assert_enqueued_emails 1 do
      post "/api/v1/groups/#{group.id}/send_email",
        params: { subject: "Hello", content: "News", test_recipient: "me@test.com" },
        headers: auth_headers(owner)
    end
    assert_equal({ "sent_count" => 1, "test" => true }, json_response)

    # A real broadcast only enqueues the fan-out job; run it inline so the
    # per-member mail actually gets enqueued for the assertion.
    assert_enqueued_emails 2 do
      perform_enqueued_jobs(only: GroupBroadcastMailJob) do
        post "/api/v1/groups/#{group.id}/send_email",
          params: { subject: "Hello", content: "News" }, headers: auth_headers(owner)
      end
    end
    assert_equal 2, json_response["sent_count"]

    post "/api/v1/groups/#{group.id}/send_email",
      params: { subject: "", content: "" }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
  end

  test "event manager can update a ticket; delete retires sold tickets, destroys unsold" do
    owner = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published")
    unsold = Ticket.create!(event: event, title: "GA")
    sold = Ticket.create!(event: event, title: "VIP")
    TicketItem.create!(ticket: sold, event: event, user: buyer, status: "succeeded")

    patch "/api/v1/events/#{event.id}/tickets/#{unsold.id}",
      params: { ticket: { title: "GA v2" } }, headers: auth_headers(buyer)
    assert_response :forbidden

    patch "/api/v1/events/#{event.id}/tickets/#{unsold.id}",
      params: { ticket: { title: "GA v2" } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "GA v2", unsold.reload.title

    delete "/api/v1/events/#{event.id}/tickets/#{unsold.id}", headers: auth_headers(owner)
    assert_response :no_content
    assert_not Ticket.exists?(unsold.id)

    delete "/api/v1/events/#{event.id}/tickets/#{sold.id}", headers: auth_headers(owner)
    assert_response :no_content
    assert_equal "inactive", sold.reload.status
  end

  private

  def create_user_in(group)
    user = create_user
    create_membership(user: user, group: group)
    user
  end
end
