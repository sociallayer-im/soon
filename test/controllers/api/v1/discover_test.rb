require "test_helper"

# Public discovery: homepage payload, global search, and a user's public
# group memberships.
class DiscoverTest < ActionDispatch::IntegrationTest
  test "discover returns featured groups, popup cities, and upcoming public events" do
    owner = create_user
    featured = create_group(owner: owner, group_tags: ["featured"])
    popup = create_group(owner: owner, group_tags: ["top"], start_date: Date.new(2026, 9, 1),
      end_date: Date.new(2026, 10, 1), location: "Chiang Mai")
    plain = create_group(owner: owner)
    upcoming = create_event(group: plain, owner: owner, status: "published")
    create_event(group: plain, owner: owner, status: "draft")

    get "/api/v1/discover"
    assert_response :success
    assert_includes json_response["groups"].map { |g| g["id"] }, featured.id
    assert_not_includes json_response["groups"].map { |g| g["id"] }, plain.id
    popup_entry = json_response["popup_cities"].find { |g| g["id"] == popup.id }
    assert_equal "Chiang Mai", popup_entry["location"]
    assert_includes json_response["events"].map { |e| e["id"] }, upcoming.id
  end

  # `communities` is the homepage grid, curated by `pin`. It is deliberately
  # not "every group": the homepage stays a fixed size however many exist, and
  # the uncurated list lives at /groups/directory instead.
  test "communities is curated by the pin tag" do
    owner = create_user
    pinned = create_group(owner: owner, group_tags: ["pin"])
    plain = create_group(owner: owner)
    top_only = create_group(owner: owner, group_tags: ["top"])

    get "/api/v1/discover"
    assert_response :success
    ids = json_response["communities"].map { |g| g["id"] }
    assert_includes ids, pinned.id
    assert_not_includes ids, plain.id
    assert_not_includes ids, top_only.id
  end

  # pin and top/featured curate different surfaces, so tagging one must not
  # move a group onto the other.
  test "a pinned group does not become a popup city" do
    owner = create_user
    pinned = create_group(owner: owner, group_tags: ["pin"])

    get "/api/v1/discover"
    assert_not_includes json_response["popup_cities"].map { |g| g["id"] }, pinned.id
    assert_not_includes json_response["groups"].map { |g| g["id"] }, pinned.id
  end

  test "communities excludes inactive groups" do
    owner = create_user
    live = create_group(owner: owner, group_tags: ["pin"])
    frozen = create_group(owner: owner, group_tags: ["pin"])
    frozen.update!(active: false)

    get "/api/v1/discover"
    ids = json_response["communities"].map { |g| g["id"] }
    assert_includes ids, live.id
    assert_not_includes ids, frozen.id
  end

  # The card shows member and event counts, and those live only in the :card
  # view — rendering the default view leaves them undefined on the client.
  test "communities carries the member and event counts the card renders" do
    owner = create_user
    group = create_group(owner: owner, group_tags: ["pin"])

    get "/api/v1/discover"
    entry = json_response["communities"].find { |g| g["id"] == group.id }
    assert entry.key?("memberships_count"), "card view must expose memberships_count"
    assert entry.key?("events_count"), "card view must expose events_count"
    assert_equal 1, entry["memberships_count"]
  end

  # The frontend renders the list in the order given rather than re-sorting,
  # so the order the API picks is the order on screen.
  test "communities is ordered oldest first" do
    owner = create_user
    first = create_group(owner: owner, group_tags: ["pin"])
    second = create_group(owner: owner, group_tags: ["pin"])

    get "/api/v1/discover"
    ids = json_response["communities"].map { |g| g["id"] }
    assert ids.index(first.id) < ids.index(second.id)
  end

  test "popup_cities is curated by the 'top' tag, not just having dates+location" do
    owner = create_user
    curated = create_group(owner: owner, group_tags: ["top"], start_date: Date.new(2026, 9, 1),
      end_date: Date.new(2026, 10, 1), location: "Chiang Mai")
    uncurated = create_group(owner: owner, start_date: Date.new(2026, 9, 1),
      end_date: Date.new(2026, 10, 1), location: "Somewhere Else")

    get "/api/v1/discover"
    assert_response :success
    ids = json_response["popup_cities"].map { |g| g["id"] }
    assert_includes ids, curated.id
    assert_not_includes ids, uncurated.id
  end

  test "popup_cities excludes a 'top'-tagged group also tagged 'hidden'" do
    owner = create_user
    hidden = create_group(owner: owner, group_tags: ["top", "hidden"], start_date: Date.new(2026, 9, 1),
      end_date: Date.new(2026, 10, 1), location: "Chiang Mai")

    get "/api/v1/discover"
    assert_response :success
    assert_not_includes json_response["popup_cities"].map { |g| g["id"] }, hidden.id
  end

  test "popup_cities exposes featured_image_url for the card image" do
    owner = create_user
    popup = create_group(owner: owner, group_tags: ["top"], start_date: Date.new(2026, 9, 1),
      end_date: Date.new(2026, 10, 1), location: "Chiang Mai",
      featured_image_url: "https://cdn.test/banner.png")

    get "/api/v1/discover"
    entry = json_response["popup_cities"].find { |g| g["id"] == popup.id }
    assert_equal "https://cdn.test/banner.png", entry["featured_image_url"]
  end

  test "search finds public content only" do
    owner = create_user(name: "zurichfan", nickname: "Zurich Fan")
    group = create_group(owner: owner, name: "zurich-hub", nickname: "Zürich Hub")
    event = create_event(group: group, owner: owner, status: "published", title: "Zurich Meetup")
    create_event(group: group, owner: owner, status: "draft", title: "Zurich Secret")
    badge_class = create_badge_class(creator: owner, title: "Zurich OG")

    get "/api/v1/search", params: { keyword: "zurich" }
    assert_response :success
    assert_equal [event.id], json_response["events"].map { |e| e["id"] }
    assert_equal [group.id], json_response["groups"].map { |g| g["id"] }
    assert_equal [owner.id], json_response["users"].map { |u| u["id"] }
    assert_equal [badge_class.id], json_response["badge_classes"].map { |b| b["id"] }
    assert_not json_response["users"].first.key?("email")
  end

  test "search requires a keyword of at least 2 chars" do
    get "/api/v1/search", params: { keyword: "z" }
    assert_response :success
    assert_empty json_response["events"]
  end

  test "user groups listing is public and filters by role" do
    user = create_user
    owned = create_group(owner: user)
    joined = create_group(owner: create_user)
    create_membership(user: user, group: joined)

    get "/api/v1/users/#{user.name}/groups"
    assert_response :success
    assert_equal [owned.id, joined.id].sort, json_response.map { |m| m["group"]["id"] }.sort

    get "/api/v1/users/#{user.name}/groups", params: { role: "owner,admin" }
    assert_equal [owned.id], json_response.map { |m| m["group"]["id"] }
  end
end
