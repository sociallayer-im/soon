require "test_helper"

class Api::V1::GroupsControllerTest < ActionDispatch::IntegrationTest
  test "create makes the creator the owner" do
    user = create_user
    assert_difference "Group.count", 1 do
      post "/api/v1/groups", params: { group: { name: "my-group" } }, headers: auth_headers(user)
    end
    assert_response :created
    group = Group.find(json_response["id"])
    assert_equal "owner", group.memberships.find_by(user: user).role
  end

  test "create requires a name" do
    user = create_user
    post "/api/v1/groups", params: { group: { name: "" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "index lists only the current user's groups" do
    user = create_user
    mine = create_group(owner: user)
    create_group # someone else's

    get "/api/v1/groups", headers: auth_headers(user)
    assert_response :success
    ids = json_response["data"].map { |g| g["id"] }
    assert_includes ids, mine.id
    assert_equal 1, ids.size
  end

  test "show works for any authenticated user" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)

    get "/api/v1/groups/#{group.id}", headers: auth_headers(outsider)
    assert_response :success
  end

  test "update requires group admin/owner" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)

    patch "/api/v1/groups/#{group.id}", params: { group: { name: "renamed" } }, headers: auth_headers(outsider)
    assert_response :forbidden

    patch "/api/v1/groups/#{group.id}", params: { group: { name: "renamed" } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "renamed", group.reload.name
  end

  test "destroy requires group admin/owner" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)

    delete "/api/v1/groups/#{group.id}", headers: auth_headers(outsider)
    assert_response :forbidden

    delete "/api/v1/groups/#{group.id}", headers: auth_headers(owner)
    assert_response :no_content
  end

  test "create sets memberships_count to 1 via the owner membership" do
    user = create_user
    post "/api/v1/groups", params: { group: { name: "counted" } }, headers: auth_headers(user)
    assert_response :created
    assert_equal 1, Group.find(json_response["id"]).memberships_count
  end

  test "update persists timezone" do
    owner = create_user
    group = create_group(owner: owner)

    patch "/api/v1/groups/#{group.id}", params: { group: { timezone: "Europe/Zurich" } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "Europe/Zurich", group.reload.timezone
  end

  test "a parent-group manager cannot manage a child group's settings (interim restriction)" do
    owner = create_user
    parent = create_group(owner: owner)
    child = create_group(name: "child-group", parent_id: parent.id)

    patch "/api/v1/groups/#{child.id}", params: { group: { name: "child-renamed" } }, headers: auth_headers(owner)
    assert_response :forbidden
    assert_equal "child-group", child.reload.name
  end

  test "create under an unmanaged parent is forbidden" do
    stranger = create_user
    other_owner = create_user
    parent = create_group(owner: other_owner)

    post "/api/v1/groups", params: { group: { name: "sneaky", parent_id: parent.id } }, headers: auth_headers(stranger)
    assert_response :forbidden
    assert_not Group.exists?(name: "sneaky")
  end

  test "a non-owner group admin can update the group" do
    owner = create_user
    admin = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")

    patch "/api/v1/groups/#{group.id}", params: { group: { nickname: "By Admin" } }, headers: auth_headers(admin)
    assert_response :success
    assert_equal "By Admin", group.reload.nickname
  end

  test "an ordinary member cannot update the group" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")

    patch "/api/v1/groups/#{group.id}", params: { group: { nickname: "Nope" } }, headers: auth_headers(member)
    assert_response :forbidden
  end

  # `pin` decides what appears in the homepage community grid, so it is
  # privileged for the same reason as featured/top — otherwise any group owner
  # could put their own group on the front page.
  test "update strips the pin tag from a non-admin" do
    owner = create_user
    group = create_group(owner: owner)

    patch "/api/v1/groups/#{group.id}", params: { group: { group_tags: ["pin", "popup"] } },
      headers: auth_headers(owner)

    assert_response :success
    assert_equal ["popup"], group.reload.group_tags
  end

  test "update lets a platform admin set the pin tag" do
    admin = create_user(admin: true)
    group = create_group(owner: admin)

    patch "/api/v1/groups/#{group.id}", params: { group: { group_tags: ["pin"] } },
      headers: auth_headers(admin)

    assert_response :success
    assert_equal ["pin"], group.reload.group_tags
  end

  # An owner editing unrelated fields must not silently drop a pin an admin set.
  test "a non-admin update keeps an existing pin tag" do
    owner = create_user
    group = create_group(owner: owner, group_tags: ["pin"])

    patch "/api/v1/groups/#{group.id}", params: { group: { group_tags: ["popup"] } },
      headers: auth_headers(owner)

    assert_response :success
    assert_equal ["pin", "popup"].sort, group.reload.group_tags.sort
  end

  # ── directory ───────────────────────────────────────────────────────────────

  test "directory is public and lists every active group regardless of tags" do
    owner = create_user
    plain = create_group(owner: owner)
    pinned = create_group(owner: owner, group_tags: ["pin"])

    get "/api/v1/groups/directory"

    assert_response :success
    ids = json_response["data"].map { |g| g["id"] }
    assert_includes ids, plain.id
    assert_includes ids, pinned.id
  end

  test "directory excludes inactive groups" do
    owner = create_user
    live = create_group(owner: owner)
    frozen = create_group(owner: owner)
    frozen.update!(active: false)

    get "/api/v1/groups/directory"
    ids = json_response["data"].map { |g| g["id"] }
    assert_includes ids, live.id
    assert_not_includes ids, frozen.id
  end

  # The admin tag controls read group_tags off these cards, and the cards show
  # member/event counts — all :card-view fields.
  test "directory renders the card view the admin controls need" do
    owner = create_user
    group = create_group(owner: owner, group_tags: ["pin"])

    get "/api/v1/groups/directory"
    entry = json_response["data"].find { |g| g["id"] == group.id }
    assert_equal ["pin"], entry["group_tags"]
    assert entry.key?("memberships_count")
    assert entry.key?("events_count")
  end

  # "directory" must not be swallowed by the /groups/:id route.
  test "directory is not shadowed by the group show route" do
    get "/api/v1/groups/directory"
    assert_response :success
    assert json_response.key?("data"), "expected a paginated collection, not a single group"
  end

  test "update accepts tag/permission/banner fields but strips privileged group_tags" do
    owner = create_user
    group = create_group(owner: owner, group_tags: ["top"])

    patch "/api/v1/groups/#{group.id}", params: { group: {
      event_tag_list: ["talk", "party"],
      can_publish_event: "member",
      social_links: { twitter: "@g" },
      banner_text: "hello",
      group_tags: ["popup", "featured"]
    } }, headers: auth_headers(owner)
    assert_response :success

    group.reload
    assert_equal %w[talk party], group.event_tag_list
    assert_equal "member", group.can_publish_event
    assert_equal({ "twitter" => "@g" }, group.social_links)
    assert_equal "hello", group.banner_text
    # "featured" (privileged) stripped; pre-existing "top" kept
    assert_equal ["popup", "top"].sort, group.group_tags.sort
  end

  test "platform admin can curate featured/top tags and delete any group" do
    admin = create_user(permissions: ["admin"])
    owner = create_user
    group = create_group(owner: owner, start_date: Date.new(2026, 9, 1), location: "Chiang Mai")

    # Curation: privileged tags pass through for a platform admin.
    patch "/api/v1/groups/#{group.id}", params: { group: { group_tags: ["popup", "featured", "top"] } },
      headers: auth_headers(admin)
    assert_response :success
    assert_equal ["popup", "featured", "top"].sort, group.reload.group_tags.sort

    # Removal: a platform admin can delete a popup city they don't own.
    delete "/api/v1/groups/#{group.id}", headers: auth_headers(admin)
    assert_response :no_content
    assert_not Group.exists?(group.id)
  end

  test "own record exposes permissions so the UI can gate admin actions" do
    admin = create_user(permissions: ["admin"])
    get "/api/v1/users/me", headers: auth_headers(admin)
    assert_equal ["admin"], json_response["permissions"]

    # Not leaked on public profiles.
    get "/api/v1/users/#{admin.name}"
    assert_not json_response.key?("permissions")
  end
end
