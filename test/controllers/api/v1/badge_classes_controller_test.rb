require "test_helper"

class Api::V1::BadgeClassesControllerTest < ActionDispatch::IntegrationTest
  test "create with no group_id — any authenticated user can create" do
    user = create_user
    assert_difference "BadgeClass.count", 1 do
      post "/api/v1/badge_classes", params: { badge_class: { name: "poap", title: "POAP" } }, headers: auth_headers(user)
    end
    assert_response :created
    assert_equal user.id, json_response["creator"]["id"]
  end

  test "create with group_id requires group admin (BadgeClassPolicy#send? via GroupPolicy#manage?)" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)

    post "/api/v1/badge_classes", params: { badge_class: { name: "g-badge", title: "G Badge", group_id: group.id } }, headers: auth_headers(outsider)
    assert_response :forbidden

    post "/api/v1/badge_classes", params: { badge_class: { name: "g-badge", title: "G Badge", group_id: group.id } }, headers: auth_headers(owner)
    assert_response :created
    assert_equal group.id, json_response["group_id"]
  end

  test "create validates name and title presence" do
    user = create_user
    post "/api/v1/badge_classes", params: { badge_class: { name: "", title: "" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "show returns a badge class" do
    user = create_user
    bc = create_badge_class(creator: user)
    get "/api/v1/badge_classes/#{bc.id}", headers: auth_headers(user)
    assert_response :success
    assert_equal bc.id, json_response["id"]
  end

  test "index filters by group_id, badge_type, creator_handle, group_handle" do
    user = create_user
    owner = create_user
    group = create_group(owner: owner, name: "the-guild")
    in_group = create_badge_class(creator: owner, group: group, badge_type: "nft")
    standalone = create_badge_class(creator: user, badge_type: "badge")

    get "/api/v1/badge_classes", params: { group_id: group.id }, headers: auth_headers(user)
    ids = json_response["data"].map { |b| b["id"] }
    assert_includes ids, in_group.id
    assert_not_includes ids, standalone.id

    get "/api/v1/badge_classes", params: { badge_type: "nft" }, headers: auth_headers(user)
    ids = json_response["data"].map { |b| b["id"] }
    assert_includes ids, in_group.id
    assert_not_includes ids, standalone.id

    get "/api/v1/badge_classes", params: { creator_handle: user.name }, headers: auth_headers(user)
    ids = json_response["data"].map { |b| b["id"] }
    assert_includes ids, standalone.id
    assert_not_includes ids, in_group.id

    get "/api/v1/badge_classes", params: { group_handle: "the-guild" }, headers: auth_headers(user)
    ids = json_response["data"].map { |b| b["id"] }
    assert_includes ids, in_group.id
  end

  test "by_user returns badge classes for every group the user belongs to" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    bc = create_badge_class(creator: owner, group: group)
    other_group_bc = create_badge_class(creator: owner, group: create_group(owner: owner))

    get "/api/v1/badge_classes/by_user", params: { handle: member.name }, headers: auth_headers(member)
    assert_response :success
    ids = json_response.map { |b| b["id"] }
    assert_includes ids, bc.id
    assert_not_includes ids, other_group_bc.id
  end

  test "by_user 404s for an unknown handle" do
    user = create_user
    get "/api/v1/badge_classes/by_user", params: { handle: "nobody" }, headers: auth_headers(user)
    assert_response :not_found
  end

  test "invites returns the badge_class plus the group's non-expired invites" do
    owner = create_user
    group = create_group(owner: owner)
    bc = create_badge_class(creator: owner, group: group)
    active_invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "a@test.com", expires_at: 30.days.from_now)
    expired_invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "b@test.com", expires_at: 1.day.ago)

    get "/api/v1/badge_classes/#{bc.id}/invites", headers: auth_headers(owner)
    assert_response :success
    assert_equal bc.id, json_response["badge_class"]["id"]
    invite_ids = json_response["invites"].map { |i| i["id"] }
    assert_includes invite_ids, active_invite.id
    assert_not_includes invite_ids, expired_invite.id
  end

  test "invites requires group manager — an outsider is forbidden" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    bc = create_badge_class(creator: owner, group: group)

    get "/api/v1/badge_classes/#{bc.id}/invites", headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "invites requires authentication" do
    owner = create_user
    group = create_group(owner: owner)
    bc = create_badge_class(creator: owner, group: group)

    get "/api/v1/badge_classes/#{bc.id}/invites"
    assert_response :unauthorized
  end

  test "invites returns an empty list for a groupless badge class" do
    user = create_user
    bc = create_badge_class(creator: user)
    get "/api/v1/badge_classes/#{bc.id}/invites", headers: auth_headers(user)
    assert_response :success
    assert_nil json_response["badge_class"]["group_id"]
    assert_equal [], json_response["invites"]
  end

  test "create now accepts can_send_badge and permissions (previously unreachable)" do
    owner = create_user
    group = create_group(owner: owner)

    post "/api/v1/badge_classes", params: {
      badge_class: { name: "collab", title: "Collab", group_id: group.id,
                     can_send_badge: "group_member_send", permissions: ["group_member_pass"] }
    }, headers: auth_headers(owner)
    assert_response :created

    bc = BadgeClass.find(json_response["id"])
    assert_equal "group_member_send", bc.can_send_badge
    assert_equal ["group_member_pass"], bc.permissions
  end

  test "group_member_send lets an ordinary member send the badge" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    bc = create_badge_class(creator: owner, group: group, can_send_badge: "group_member_send")

    # A plain member can now issue a code voucher for this class.
    post "/api/v1/vouchers", params: { badge_class_id: bc.id }, headers: auth_headers(member)
    assert_response :created
  end

  test "create rejects an invalid can_send_badge value" do
    owner = create_user
    group = create_group(owner: owner)

    post "/api/v1/badge_classes", params: {
      badge_class: { name: "x", title: "X", group_id: group.id, can_send_badge: "everyone" }
    }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
  end
end
