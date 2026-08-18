require "test_helper"

class Api::V1::MembershipsControllerTest < ActionDispatch::IntegrationTest
  test "create is admin-only direct-add, not self-join" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)

    # A random authenticated user cannot self-join.
    post "/api/v1/groups/#{group.id}/memberships", params: { user_id: outsider.id }, headers: auth_headers(outsider)
    assert_response :forbidden
    assert_not group.memberships.exists?(user: outsider)
  end

  test "create lets a group admin add a known user directly" do
    owner = create_user
    target = create_user
    group = create_group(owner: owner)

    post "/api/v1/groups/#{group.id}/memberships", params: { user_id: target.id, role: "member" }, headers: auth_headers(owner)
    assert_response :created
    assert_equal "member", group.memberships.find_by(user: target).role
  end

  test "create with an invalid role renders 422, not a misleading success" do
    owner = create_user
    target = create_user
    group = create_group(owner: owner)

    post "/api/v1/groups/#{group.id}/memberships", params: { user_id: target.id, role: "superadmin" }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_not group.memberships.exists?(user: target)
  end

  test "create with an invalid role on an EXISTING member does not report success while leaving the role unchanged" do
    owner = create_user
    target = create_user
    group = create_group(owner: owner)
    create_membership(user: target, group: group, role: "member")

    post "/api/v1/groups/#{group.id}/memberships", params: { user_id: target.id, role: "superadmin" }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_equal "member", group.memberships.find_by(user: target).role
  end

  test "create 404s for an unknown user_id" do
    owner = create_user
    group = create_group(owner: owner)

    post "/api/v1/groups/#{group.id}/memberships", params: { user_id: "nope" }, headers: auth_headers(owner)
    assert_response :not_found
  end

  test "index lists memberships" do
    owner = create_user
    group = create_group(owner: owner)

    get "/api/v1/groups/#{group.id}/memberships", headers: auth_headers(owner)
    assert_response :success
    assert_equal 1, json_response["data"].size
  end

  test "update role requires group admin" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    membership = group.memberships.find_by(user: member)

    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}", params: { membership: { role: "manager" } }, headers: auth_headers(member)
    assert_response :forbidden

    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}", params: { membership: { role: "manager" } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "manager", membership.reload.role
  end

  test "a parent-group manager may promote a child-group member to manager" do
    parent_owner = create_user
    parent = create_group(owner: parent_owner)
    child = create_group(name: "child-group", parent_id: parent.id)
    target = create_user
    create_membership(user: target, group: child, role: "member")
    membership = child.memberships.find_by(user: target)

    patch "/api/v1/groups/#{child.id}/memberships/#{membership.id}", params: { membership: { role: "manager" } },
      headers: auth_headers(parent_owner)
    assert_response :success
    assert_equal "manager", membership.reload.role
  end

  # Was allowed until 2026-08-18, when demotion became the owner's alone —
  # one rule for everyone rather than one that changes with where you stand.
  # The parent-group grant is now its promoting half only.
  test "a parent-group manager may NOT demote a child-group manager" do
    parent_owner = create_user
    parent = create_group(owner: parent_owner)
    child = create_group(name: "child-group", parent_id: parent.id)
    target = create_user
    create_membership(user: target, group: child, role: "manager")
    membership = child.memberships.find_by(user: target)

    patch "/api/v1/groups/#{child.id}/memberships/#{membership.id}", params: { membership: { role: "member" } },
      headers: auth_headers(parent_owner)
    assert_response :forbidden
    assert_equal "manager", membership.reload.role
  end

  test "a parent-group manager cannot grant the owner role on a child group" do
    parent_owner = create_user
    parent = create_group(owner: parent_owner)
    child = create_group(name: "child-group", parent_id: parent.id)
    target = create_user
    create_membership(user: target, group: child, role: "member")
    membership = child.memberships.find_by(user: target)

    patch "/api/v1/groups/#{child.id}/memberships/#{membership.id}", params: { membership: { role: "owner" } },
      headers: auth_headers(parent_owner)
    assert_response :forbidden
    assert_equal "member", membership.reload.role
  end

  test "a parent-group manager cannot directly add a new member to a child group" do
    parent_owner = create_user
    parent = create_group(owner: parent_owner)
    child = create_group(name: "child-group", parent_id: parent.id)
    target = create_user

    post "/api/v1/groups/#{child.id}/memberships", params: { user_id: target.id, role: "member" },
      headers: auth_headers(parent_owner)
    assert_response :forbidden
  end

  test "a parent-group manager cannot remove a child-group member" do
    parent_owner = create_user
    parent = create_group(owner: parent_owner)
    child = create_group(name: "child-group", parent_id: parent.id)
    target = create_user
    create_membership(user: target, group: child, role: "member")
    membership = child.memberships.find_by(user: target)

    delete "/api/v1/groups/#{child.id}/memberships/#{membership.id}", headers: auth_headers(parent_owner)
    assert_response :forbidden
  end

  # ── admin_notification ──────────────────────────────────────────────────────

  test "a manager can mute their own admin notifications without role rights" do
    owner = create_user
    manager = create_user
    group = create_group(owner: owner)
    create_membership(user: manager, group: group, role: "manager")
    membership = group.memberships.find_by(user: manager)

    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}",
      params: { membership: { admin_notification: false } }, headers: auth_headers(manager)

    assert_response :success
    assert_not membership.reload.admin_notification
    assert_equal "manager", membership.role, "toggling a preference must not touch the role"
  end

  test "an owner can mute an admin's notifications for them" do
    owner = create_user
    manager = create_user
    group = create_group(owner: owner)
    create_membership(user: manager, group: group, role: "manager")
    membership = group.memberships.find_by(user: manager)

    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}",
      params: { membership: { admin_notification: false } }, headers: auth_headers(owner)

    assert_response :success
    assert_not membership.reload.admin_notification
  end

  test "a member cannot set admin_notification on someone else's membership" do
    owner = create_user
    other = create_user
    group = create_group(owner: owner)
    create_membership(user: other, group: group, role: "member")
    owner_membership = group.memberships.find_by(user: owner)

    patch "/api/v1/groups/#{group.id}/memberships/#{owner_membership.id}",
      params: { membership: { admin_notification: false } }, headers: auth_headers(other)

    assert_response :forbidden
    assert owner_membership.reload.admin_notification
  end

  # The setting only governs mail sent to owners/managers. Accepting it on a
  # plain member would store a value nothing ever reads and report success.
  test "admin_notification is rejected on a plain member row" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    membership = group.memberships.find_by(user: member)

    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}",
      params: { membership: { admin_notification: false } }, headers: auth_headers(member)

    assert_response :forbidden
  end

  test "role and admin_notification can be set in one request" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "manager")
    membership = group.memberships.find_by(user: member)

    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}",
      params: { membership: { role: "member", admin_notification: false } }, headers: auth_headers(owner)

    assert_response :success
    membership.reload
    assert_equal "member", membership.role
    assert_not membership.admin_notification
  end

  test "an update naming no attribute is a 422, not a silent success" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    membership = group.memberships.find_by(user: member)

    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}",
      params: { membership: { nickname: "nope" } }, headers: auth_headers(owner)

    assert_response :unprocessable_entity
    assert_equal "member", membership.reload.role
  end

  test "update rejects an invalid role value" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    membership = group.memberships.find_by(user: member)

    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}", params: { membership: { role: "superadmin" } }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
  end

  test "destroy allows self-leave" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    membership = group.memberships.find_by(user: member)

    delete "/api/v1/groups/#{group.id}/memberships/#{membership.id}", headers: auth_headers(member)
    assert_response :no_content
  end

  test "destroy allows admin to remove someone else" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    membership = group.memberships.find_by(user: member)

    delete "/api/v1/groups/#{group.id}/memberships/#{membership.id}", headers: auth_headers(owner)
    assert_response :no_content
  end

  test "destroy forbids a random member removing another member" do
    owner = create_user
    member1 = create_user
    member2 = create_user
    group = create_group(owner: owner)
    create_membership(user: member1, group: group, role: "member")
    create_membership(user: member2, group: group, role: "member")
    membership2 = group.memberships.find_by(user: member2)

    delete "/api/v1/groups/#{group.id}/memberships/#{membership2.id}", headers: auth_headers(member1)
    assert_response :forbidden
  end

  test "create forbids a non-owner admin from granting the owner role" do
    owner = create_user
    admin = create_user
    target = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")

    post "/api/v1/groups/#{group.id}/memberships", params: { user_id: target.id, role: "owner" }, headers: auth_headers(admin)
    assert_response :forbidden
    assert_not group.memberships.exists?(user: target)
  end

  test "update forbids a non-owner admin from self-promoting to owner" do
    owner = create_user
    admin = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")
    membership = group.memberships.find_by(user: admin)

    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}", params: { membership: { role: "owner" } }, headers: auth_headers(admin)
    assert_response :forbidden
    assert_equal "manager", membership.reload.role
  end

  test "update forbids a non-owner admin from demoting the owner" do
    owner = create_user
    admin = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")
    owner_membership = group.memberships.find_by(user: owner)

    patch "/api/v1/groups/#{group.id}/memberships/#{owner_membership.id}", params: { membership: { role: "member" } }, headers: auth_headers(admin)
    assert_response :forbidden
    assert_equal "owner", owner_membership.reload.role
  end

  test "destroy refuses to remove the last owner of a group" do
    owner = create_user
    group = create_group(owner: owner)
    membership = group.memberships.find_by(user: owner)

    delete "/api/v1/groups/#{group.id}/memberships/#{membership.id}", headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert group.memberships.exists?(user: owner)
  end

  test "destroy allows removing an owner when another owner remains" do
    owner1 = create_user
    owner2 = create_user
    group = create_group(owner: owner1)
    create_membership(user: owner2, group: group, role: "owner")
    membership2 = group.memberships.find_by(user: owner2)

    delete "/api/v1/groups/#{group.id}/memberships/#{membership2.id}", headers: auth_headers(owner1)
    assert_response :no_content
    assert_not group.memberships.exists?(user: owner2)
  end

  test "index is public and does not leak member email" do
    owner = create_user
    group = create_group(owner: owner)

    # The roster is public — group pages show members without login.
    get "/api/v1/groups/#{group.id}/memberships"
    assert_response :success

    # The roster never exposes member email (UserBlueprint default view).
    get "/api/v1/groups/#{group.id}/memberships", headers: auth_headers(owner)
    assert_response :success
    assert_not json_response["data"].first["user"].key?("email")
  end

  test "a non-owner admin can add and remove ordinary members" do
    owner = create_user
    admin = create_user
    target = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")

    post "/api/v1/groups/#{group.id}/memberships", params: { user_id: target.id, role: "member" }, headers: auth_headers(admin)
    assert_response :created
    membership = group.memberships.find_by(user: target)

    delete "/api/v1/groups/#{group.id}/memberships/#{membership.id}", headers: auth_headers(admin)
    assert_response :no_content
    assert_not group.memberships.exists?(user: target)
  end

  test "an admin cannot remove an owner" do
    owner = create_user
    admin = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")
    owner_membership = group.memberships.find_by(user: owner)

    delete "/api/v1/groups/#{group.id}/memberships/#{owner_membership.id}", headers: auth_headers(admin)
    assert_response :forbidden
    assert group.memberships.exists?(user: owner, role: "owner")
  end

  test "counter_cache keeps memberships_count correct across add and remove" do
    owner = create_user
    target = create_user
    group = create_group(owner: owner)
    assert_equal 1, group.reload.memberships_count

    post "/api/v1/groups/#{group.id}/memberships", params: { user_id: target.id, role: "member" }, headers: auth_headers(owner)
    assert_response :created
    assert_equal 2, group.reload.memberships_count

    membership = group.memberships.find_by(user: target)
    delete "/api/v1/groups/#{group.id}/memberships/#{membership.id}", headers: auth_headers(owner)
    assert_response :no_content
    assert_equal 1, group.reload.memberships_count
  end

  # A manager may grow the team but not shrink it: peers being able to strip
  # each other's role is how one manager removes the others, and the person
  # demoted cannot undo it. Promotion is additive and an owner can reverse it.
  test "a manager promotes a member but cannot demote anyone" do
    owner = create_user
    manager = create_user
    peer = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: manager, group: group, role: "manager")
    create_membership(user: peer, group: group, role: "manager")
    create_membership(user: member, group: group)

    set_role = ->(target, role, actor) {
      membership = Membership.find_by(group: group, user: target)
      patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}",
            params: { membership: { role: role } }, headers: auth_headers(actor)
    }

    set_role.(member, "manager", manager)
    assert_response :success
    assert_equal "manager", Membership.find_by(group: group, user: member).role

    set_role.(peer, "member", manager)
    assert_response :forbidden
    assert_equal "manager", Membership.find_by(group: group, user: peer).role

    # Not even their own — stepping down is still the owner's call.
    set_role.(manager, "member", manager)
    assert_response :forbidden

    # The owner may do both.
    set_role.(peer, "member", owner)
    assert_response :success
    assert_equal "member", Membership.find_by(group: group, user: peer).role
  end

  # The parent-group grant reads as a two-way toggle in GroupPolicy, but
  # demotion is the owner's alone — one rule rather than two that differ by
  # where you stand.
  test "a parent group's manager may promote in a child group but not demote" do
    parent_owner = create_user
    parent = create_group(owner: parent_owner)
    child = create_group(parent_id: parent.id)
    child_owner = create_user
    child.add_member(child_owner.id, "owner")
    member = create_user
    create_membership(user: member, group: child)

    membership = Membership.find_by(group: child, user: member)
    patch "/api/v1/groups/#{child.id}/memberships/#{membership.id}",
          params: { membership: { role: "manager" } }, headers: auth_headers(parent_owner)
    assert_response :success

    patch "/api/v1/groups/#{child.id}/memberships/#{membership.id}",
          params: { membership: { role: "member" } }, headers: auth_headers(parent_owner)
    assert_response :forbidden
    assert_equal "manager", membership.reload.role
  end

  # Removal follows the same rule as demotion — it is strictly worse, so
  # allowing it would have made the demotion rule decorative.
  test "a manager removes a member but not another manager" do
    owner = create_user
    manager = create_user
    peer = create_user
    member = create_user
    group = create_group(owner: owner)
    create_membership(user: manager, group: group, role: "manager")
    create_membership(user: peer, group: group, role: "manager")
    create_membership(user: member, group: group)

    remove = ->(target, actor) {
      m = Membership.find_by(group: group, user: target)
      delete "/api/v1/groups/#{group.id}/memberships/#{m.id}", headers: auth_headers(actor)
    }

    remove.(peer, manager)
    assert_response :forbidden
    assert Membership.exists?(group: group, user: peer)

    remove.(member, manager)
    assert_response :success
    assert_not Membership.exists?(group: group, user: member)

    # Owners still can, and anyone may still leave of their own accord.
    remove.(peer, owner)
    assert_response :success
    remove.(manager, manager)
    assert_response :success
  end
end
