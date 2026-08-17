require "test_helper"

# Public, unauthenticated reads powering the frontend's server-rendered pages:
# profile pages (/profile/<name>), group pages (/group/<name>), event detail.
# Identifiers resolve by TSID or unique name slug.
class PublicReadsTest < ActionDispatch::IntegrationTest
  # --- users ---

  test "user profile is public by name and hides email" do
    user = create_user(nickname: "Alice", bio: "hi", eth: "0x" + "a" * 40)

    get "/api/v1/users/#{user.name}"
    assert_response :success
    assert_equal user.id, json_response["id"]
    assert_equal "hi", json_response["bio"]
    assert_equal user.eth, json_response["eth"]
    assert_not json_response.key?("email"), "public profile must not leak email"
  end

  test "user show by id still works and me requires auth" do
    user = create_user

    get "/api/v1/users/#{user.id}"
    assert_response :success
    assert_equal user.name, json_response["name"]

    get "/api/v1/users/me"
    assert_response :unauthorized

    get "/api/v1/users/me", headers: auth_headers(user)
    assert_response :success
    assert_equal user.email, json_response["email"]
  end

  test "authenticated user viewing own profile by name gets private fields" do
    user = create_user
    get "/api/v1/users/#{user.name}", headers: auth_headers(user)
    assert_response :success
    assert_equal user.email, json_response["email"]
  end

  test "unknown user name 404s" do
    get "/api/v1/users/nobody_here"
    assert_response :not_found
  end

  # --- groups ---

  test "group detail is public by slug with full fields" do
    owner = create_user
    group = create_group(owner: owner, nickname: "Edge City", timezone: "Asia/Tokyo",
      social_links: { "twitter" => "@edge" }, group_tags: ["popup"])
    track = create_track(group: group)
    venue = create_venue(group: group, owner: owner)

    get "/api/v1/groups/#{group.name}"
    assert_response :success
    assert_equal group.id, json_response["id"]
    assert_equal "Edge City", json_response["nickname"]
    assert_equal "Asia/Tokyo", json_response["timezone"]
    assert_equal({ "twitter" => "@edge" }, json_response["social_links"])
    assert_equal ["popup"], json_response["group_tags"]
    assert_equal 1, json_response["memberships_count"]
    assert_equal [track.id], json_response["tracks"].map { |t| t["id"] }
    assert_equal [venue.id], json_response["venues"].map { |v| v["id"] }
    assert_equal "owner", json_response["memberships"].first["role"]
    assert_not json_response["memberships"].first["user"].key?("email")
  end

  test "group detail includes parent and children" do
    owner = create_user
    parent = create_group(owner: owner)
    child = create_group(owner: owner, parent_id: parent.id)

    get "/api/v1/groups/#{parent.id}"
    assert_response :success
    assert_equal [child.id], json_response["children"].map { |c| c["id"] }

    get "/api/v1/groups/#{child.id}"
    assert_equal parent.id, json_response["parent"]["id"]
  end

  test "group name must be a unique slug" do
    create_group(name: "edge-city")
    dup = Group.new(name: "edge-city")
    assert_not dup.valid?

    assert_not Group.new(name: "Has Spaces").valid?
    # Underscores were legal for a group and are not any more — the shape is
    # now the same one users get. See HandleName.
    assert_not Group.new(name: "edge_city2").valid?
    assert Group.new(name: "edge-city2").valid?
  end

  # --- events ---

  test "public event detail is readable without auth and includes owner and tickets" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published")
    ticket = Ticket.create!(event: event, title: "GA")

    get "/api/v1/events/#{event.id}"
    assert_response :success
    assert_equal owner.id, json_response["owner"]["id"]
    assert_equal [ticket.id], json_response["tickets"].map { |t| t["id"] }
  end

  test "draft events stay hidden from anonymous viewers" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "draft")

    get "/api/v1/events/#{event.id}"
    assert_response :forbidden

    get "/api/v1/events/#{event.id}", headers: auth_headers(owner)
    assert_response :success
  end

  # --- freeze ---

  test "only an owner can freeze a group" do
    owner = create_user
    admin = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")

    post "/api/v1/groups/#{group.id}/freeze", headers: auth_headers(admin)
    assert_response :forbidden
    assert group.reload.active

    post "/api/v1/groups/#{group.id}/freeze", headers: auth_headers(owner)
    assert_response :success
    assert_not group.reload.active
  end
end
