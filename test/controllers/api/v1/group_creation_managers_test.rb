require "test_helper"
class Api::V1::GroupCreationManagersTest < ActionDispatch::IntegrationTest
  test "creator remains owner and selected managers are added atomically while group awaits review" do
    owner = create_user
    manager = create_user
    name = "node-#{unique_suffix}"
    post "/api/v1/groups", params: {group: {name: name, nickname: "测试节点"}, manager_ids: [manager.id, manager.id, owner.id], idempotency_key: "managers-#{unique_suffix}"}, as: :json, headers: auth_headers(owner)
    assert_response :created
    group = Group.find(json_response["id"])
    assert_equal "owner", group.memberships.find_by!(user: owner).role
    assert_equal "manager", group.memberships.find_by!(user: manager).role
    assert_equal 2, group.memberships.count
    assert_equal "pending", group.review_status
    assert_not group.active?
    assert Activity.for_receiver(manager).exists?(action: "surf/membership_role")
    assert_not manager.reload.platform_admin?
  end

  test "invalid or inactive managers reject the entire creation without orphaning a group" do
    owner = create_user
    inactive = create_user(active: false)
    ["missing-user", inactive.id].each do |id|
      assert_no_difference ["Group.count", "Membership.count"] do
        post "/api/v1/groups", params: {group: {name: "node-#{unique_suffix}"}, manager_ids: [id]}, as: :json, headers: auth_headers(owner)
      end
      assert_response :unprocessable_entity
    end
  end

  test "idempotent replay does not duplicate memberships or manager notices" do
    owner = create_user
    manager = create_user
    body = {group: {name: "node-#{unique_suffix}"}, manager_ids: [manager.id], idempotency_key: "group-managers-#{unique_suffix}"}
    2.times do
      post "/api/v1/groups", params: body, as: :json, headers: auth_headers(owner)
      assert_response :created
    end
    group = Group.find(json_response["id"])
    assert_equal 2, group.memberships.count
    assert_equal 1, Activity.for_receiver(manager).where(item: group, action: "surf/membership_role").count
  end
end
