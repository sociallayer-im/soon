require "test_helper"

class Api::V1::EventRolesControllerTest < ActionDispatch::IntegrationTest
  test "index lists event roles" do
    owner = create_user
    cohost = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    event.event_roles.create!(item_id: cohost.id, item_type: "User", role: "co_host")

    get "/api/v1/events/#{event.id}/event_roles", headers: auth_headers(owner)
    assert_response :success
    assert_equal 1, json_response.size
  end

  test "create requires event manager: owner, existing EventRole holder, or group admin" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    target = create_user

    post "/api/v1/events/#{event.id}/event_roles",
      params: { event_role: { item_id: target.id, item_type: "User", role: "speaker" } },
      headers: auth_headers(outsider)
    assert_response :forbidden
    assert_equal 0, event.event_roles.count
  end

  test "create succeeds for the event owner" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    target = create_user

    assert_difference "EventRole.count", 1 do
      post "/api/v1/events/#{event.id}/event_roles",
        params: { event_role: { item_id: target.id, item_type: "User", role: "speaker" } },
        headers: auth_headers(owner)
    end
    assert_response :created
  end

  test "create succeeds for a group admin who isn't the owner" do
    owner = create_user
    admin = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")
    event = create_event(group: group, owner: owner)
    target = create_user

    post "/api/v1/events/#{event.id}/event_roles",
      params: { event_role: { item_id: target.id, item_type: "User", role: "speaker" } },
      headers: auth_headers(admin)
    assert_response :created
  end

  test "create succeeds for an existing EventRole holder" do
    owner = create_user
    cohost = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    event.event_roles.create!(item_id: cohost.id, item_type: "User", role: "co_host")
    target = create_user

    post "/api/v1/events/#{event.id}/event_roles",
      params: { event_role: { item_id: target.id, item_type: "User", role: "speaker" } },
      headers: auth_headers(cohost)
    assert_response :created
  end

  test "create validates role inclusion" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    target = create_user

    post "/api/v1/events/#{event.id}/event_roles",
      params: { event_role: { item_id: target.id, item_type: "User", role: "superadmin" } },
      headers: auth_headers(owner)
    assert_response :unprocessable_entity
  end

  test "create validates item_type inclusion" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    target = create_user

    post "/api/v1/events/#{event.id}/event_roles",
      params: { event_role: { item_id: target.id, item_type: "widget", role: "speaker" } },
      headers: auth_headers(owner)
    assert_response :unprocessable_entity
  end

  test "create rejects a duplicate item per event" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    target = create_user
    event.event_roles.create!(item_id: target.id, item_type: "User", role: "speaker")

    post "/api/v1/events/#{event.id}/event_roles",
      params: { event_role: { item_id: target.id, item_type: "User", role: "co_host" } },
      headers: auth_headers(owner)
    assert_response :unprocessable_entity
  end

  test "update requires event manager" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    target = create_user
    role = event.event_roles.create!(item_id: target.id, item_type: "User", role: "speaker")

    patch "/api/v1/events/#{event.id}/event_roles/#{role.id}",
      params: { event_role: { role: "co_host" } }, headers: auth_headers(outsider)
    assert_response :forbidden

    patch "/api/v1/events/#{event.id}/event_roles/#{role.id}",
      params: { event_role: { role: "co_host" } }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "co_host", role.reload.role
  end

  test "update 404s for an unknown role" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)

    patch "/api/v1/events/#{event.id}/event_roles/does-not-exist",
      params: { event_role: { role: "co_host" } }, headers: auth_headers(owner)
    assert_response :not_found
  end

  test "destroy requires event manager" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    target = create_user
    role = event.event_roles.create!(item_id: target.id, item_type: "User", role: "speaker")

    delete "/api/v1/events/#{event.id}/event_roles/#{role.id}", headers: auth_headers(outsider)
    assert_response :forbidden

    delete "/api/v1/events/#{event.id}/event_roles/#{role.id}", headers: auth_headers(owner)
    assert_response :no_content
  end

  test "polymorphic item_type also accepts group" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    other_group = create_group

    post "/api/v1/events/#{event.id}/event_roles",
      params: { event_role: { item_id: other_group.id, item_type: "Group", role: "group_host" } },
      headers: auth_headers(owner)
    assert_response :created
    assert_equal "Group", json_response["item_type"]
  end
end
