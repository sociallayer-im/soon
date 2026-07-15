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

    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}", params: { membership: { role: "admin" } }, headers: auth_headers(member)
    assert_response :forbidden

    patch "/api/v1/groups/#{group.id}/memberships/#{membership.id}", params: { membership: { role: "admin" } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "admin", membership.reload.role
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
end
