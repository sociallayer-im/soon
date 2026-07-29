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
end
