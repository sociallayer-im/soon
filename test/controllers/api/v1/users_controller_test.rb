require "test_helper"

class Api::V1::UsersControllerTest < ActionDispatch::IntegrationTest
  test "show 'me' returns the current user" do
    user = create_user
    get "/api/v1/users/me", headers: auth_headers(user)
    assert_response :success
    assert_equal user.id, json_response["id"]
  end

  test "show by id returns any user" do
    user = create_user
    other = create_user
    get "/api/v1/users/#{other.id}", headers: auth_headers(user)
    assert_response :success
    assert_equal other.id, json_response["id"]
  end

  test "show 404s for an unknown id" do
    user = create_user
    get "/api/v1/users/does-not-exist", headers: auth_headers(user)
    assert_response :not_found
  end

  test "show requires authentication" do
    get "/api/v1/users/me"
    assert_response :unauthorized
  end

  test "update changes the current user's name" do
    user = create_user
    patch "/api/v1/users/#{user.id}", params: { user: { name: "new-name" } }, headers: auth_headers(user)
    assert_response :success
    assert_equal "new-name", user.reload.name
  end

  test "update ignores unpermitted params like email" do
    user = create_user
    original_email = user.email
    patch "/api/v1/users/#{user.id}", params: { user: { name: "new-name", email: "hacked@test.com" } }, headers: auth_headers(user)
    assert_response :success
    assert_equal original_email, user.reload.email
  end

  test "update rejects a blank name" do
    user = create_user
    patch "/api/v1/users/#{user.id}", params: { user: { name: "" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "show reveals own email but hides other users' email" do
    user = create_user
    other = create_user

    get "/api/v1/users/me", headers: auth_headers(user)
    assert_response :success
    assert_equal user.email, json_response["email"]

    get "/api/v1/users/#{other.id}", headers: auth_headers(user)
    assert_response :success
    assert_not json_response.key?("email")
  end

  # The phone number is PII on the same footing as the email, and `wechat` says
  # which sign-in someone used — neither belongs on a profile page anyone can
  # read. The frontend reads both off /users/me to decide the onboarding route.
  test "show reveals own phone and wechat flag, and hides both from everyone else" do
    user = create_user(phone: "+8613800138099", wechat_openid: "openid_#{unique_suffix}")
    other = create_user

    get "/api/v1/users/me", headers: auth_headers(user)
    assert_response :success
    assert_equal "+8613800138099", json_response["phone"]
    assert_equal true, json_response["wechat"]

    get "/api/v1/users/#{user.id}", headers: auth_headers(other)
    assert_response :success
    assert_not json_response.key?("phone")
    assert_not json_response.key?("wechat")
  end

  # An account that never touched WeChat must report false, not nil — the
  # frontend's phone step keys off it and `undefined` would read as "not a
  # WeChat account" by accident rather than by answer.
  test "the wechat flag is false for an account that signed in another way" do
    get "/api/v1/users/me", headers: auth_headers(create_user)
    assert_response :success
    assert_equal false, json_response["wechat"]
  end

  test "update rejects a name that is not a valid slug" do
    user = create_user
    patch "/api/v1/users/#{user.id}", params: { user: { name: "Not A Slug" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "update rejects a name already taken by another user" do
    taken = create_user(name: "taken-name")
    user = create_user
    patch "/api/v1/users/#{user.id}", params: { user: { name: "taken-name" } }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "name is the unique identifier — two users cannot share one" do
    create_user(name: "duplicate-name")
    assert_raises(ActiveRecord::RecordInvalid) { create_user(name: "duplicate-name") }
  end

  test "name must be a lowercase slug at creation time" do
    assert_raises(ActiveRecord::RecordInvalid) { create_user(name: "Has Spaces") }
    assert_raises(ActiveRecord::RecordInvalid) { create_user(name: "UPPER") }
  end

  test "a user is resolvable by name via the badge owner filter" do
    owner = create_user(name: "resolvable-user")
    bc = create_badge_class(creator: owner)
    badge = create_badge(badge_class: bc, creator: owner, owner: owner)

    get "/api/v1/badges", params: { owner_handle: "resolvable-user" }, headers: auth_headers(owner)
    assert_response :success
    assert_equal [badge.id], json_response["data"].map { |b| b["id"] }
  end

  test "groups lists a user's active memberships in active groups" do
    user = create_user
    active_group = create_group(owner: user)

    get "/api/v1/users/#{user.id}/groups"
    assert_response :success
    ids = json_response.map { |m| m["group"]["id"] }
    assert_equal [active_group.id], ids
  end

  test "groups excludes memberships in a deactivated (frozen) group" do
    user = create_user
    active_group = create_group(owner: user)
    frozen_group = create_group(owner: user, active: false)

    get "/api/v1/users/#{user.id}/groups"
    assert_response :success
    ids = json_response.map { |m| m["group"]["id"] }
    assert_equal [active_group.id], ids
    assert_not_includes ids, frozen_group.id
  end

  test "groups excludes an inactive membership" do
    user = create_user
    group = create_group
    create_membership(user: user, group: group, active: false)

    get "/api/v1/users/#{user.id}/groups"
    assert_response :success
    assert_empty json_response
  end

  test "groups does not require authentication" do
    user = create_user
    create_group(owner: user)

    get "/api/v1/users/#{user.id}/groups"
    assert_response :success
  end

  test "groups orders by when the user joined, not when the group was created" do
    user = create_user
    older_group = create_group(created_at: 2.days.ago)
    newer_group = create_group(created_at: 1.day.ago)
    # join the newer group first, so a group-creation-time sort would list them reversed
    create_membership(user: user, group: newer_group, created_at: 2.hours.ago)
    create_membership(user: user, group: older_group, created_at: 1.hour.ago)

    get "/api/v1/users/#{user.id}/groups"
    assert_response :success
    ids = json_response.map { |m| m["group"]["id"] }
    assert_equal [newer_group.id, older_group.id], ids
  end

  test "merge requires platform admin" do
    admin = create_user
    from = create_user
    into = create_user
    post "/api/v1/users/merge", params: { from_id: from.id, into_id: into.id }, headers: auth_headers(admin)
    assert_response :forbidden
    assert User.exists?(from.id)
  end

  test "merge moves events, badges, and comments onto the target and destroys the source" do
    admin = create_user(admin: true)
    from = create_user
    into = create_user
    group = create_group(owner: into)
    event = create_event(group: group, owner: from)

    post "/api/v1/users/merge", params: { from_id: from.id, into_id: into.id }, headers: auth_headers(admin)
    assert_response :success
    assert_not User.exists?(from.id)
    assert_equal into.id, event.reload.owner_id
  end

  test "merge dedupes memberships in a shared group, keeping the higher role" do
    admin = create_user(admin: true)
    from = create_user
    into = create_user
    group = create_group
    create_membership(user: from, group: group, role: "manager")
    create_membership(user: into, group: group, role: "member")

    post "/api/v1/users/merge", params: { from_id: from.id, into_id: into.id }, headers: auth_headers(admin)
    assert_response :success
    assert_equal "manager", Membership.find_by(user: into, group: group).role
    assert_equal 1, Membership.where(group: group, user: into).count
  end

  test "merge repoints group_invites sent by the source (FK would otherwise block destroy)" do
    admin = create_user(admin: true)
    from = create_user
    into = create_user
    group = create_group(owner: from)
    invite = GroupInvite.create!(group: group, sender: from, receiver_address_type: "email", receiver_address: "x@test.com")

    post "/api/v1/users/merge", params: { from_id: from.id, into_id: into.id }, headers: auth_headers(admin)
    assert_response :success
    assert_equal into.id, invite.reload.sender_id
  end

  test "merge dedupes event_roles, keeping only one role per event for the target" do
    admin = create_user(admin: true)
    from = create_user
    into = create_user
    group = create_group(owner: into)
    event = create_event(group: group, owner: into)
    EventRole.create!(event: event, item: from, role: "speaker")
    EventRole.create!(event: event, item: into, role: "co_host")

    post "/api/v1/users/merge", params: { from_id: from.id, into_id: into.id }, headers: auth_headers(admin)
    assert_response :success
    assert_equal 1, EventRole.where(event: event, item_type: "User", item_id: into.id).count
  end

  test "merge refuses to merge a user into itself" do
    admin = create_user(admin: true)
    user = create_user
    post "/api/v1/users/merge", params: { from_id: user.id, into_id: user.id }, headers: auth_headers(admin)
    assert_response :unprocessable_entity
  end

  test "by_email requires platform admin" do
    user = create_user
    get "/api/v1/users/by_email", params: { email: user.email }, headers: auth_headers(user)
    assert_response :forbidden
  end

  test "by_email requires authentication" do
    get "/api/v1/users/by_email", params: { email: "x@test.com" }
    assert_response :unauthorized
  end

  test "by_email finds a user case- and whitespace-insensitively without exposing email" do
    admin = create_user(admin: true)
    target = create_user(email: "Target.Person@Test.com")
    get "/api/v1/users/by_email", params: { email: "  TARGET.person@test.com " }, headers: auth_headers(admin)
    assert_response :success
    assert_equal target.id, json_response["id"]
    assert_nil json_response["email"]
  end

  test "by_email 404s for an unknown email and 422s for a blank one" do
    admin = create_user(admin: true)
    get "/api/v1/users/by_email", params: { email: "nobody@test.com" }, headers: auth_headers(admin)
    assert_response :not_found
    get "/api/v1/users/by_email", params: { email: "" }, headers: auth_headers(admin)
    assert_response :unprocessable_entity
  end
end
