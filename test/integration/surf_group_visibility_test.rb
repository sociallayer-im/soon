require "test_helper"

class SurfGroupVisibilityTest < ActionDispatch::IntegrationTest
  test "Surf filters the directory, group details and events before pagination, including for admins" do
    previous = ENV["SURF_GROUP_IDS"]
    owner = create_user(admin: true)
    allowed = create_group(owner: owner)
    hidden = create_group(owner: owner)
    hidden_event = create_event(group: hidden, owner: owner, status: "published")
    ENV["SURF_GROUP_IDS"] = " #{allowed.id}, #{allowed.id} "
    host! "surf.soda.fan"
    get "/api/v1/groups/directory", params: {limit: 1}
    assert_response :success
    assert_equal [allowed.id], json_response.fetch("data").pluck("id")
    get "/api/v1/groups/#{hidden.name}", headers: auth_headers(owner)
    assert_response :not_found
    get "/api/v1/events/#{hidden_event.id}", headers: auth_headers(owner)
    assert_response :not_found
    get "/api/v1/groups/#{hidden.id}", headers: {"X-Forwarded-Host" => "sola.day"}
    assert_response :not_found
    ENV.delete("SURF_GROUP_IDS")
    get "/api/v1/groups/directory"
    assert_response :success
    assert_empty json_response.fetch("data")
    host! "sola.day"
    get "/api/v1/groups/#{hidden.id}", headers: auth_headers(owner)
    assert_response :success
  ensure
    previous ? ENV["SURF_GROUP_IDS"] = previous : ENV.delete("SURF_GROUP_IDS")
  end
end

class SurfGroupCreationTest < ActionDispatch::IntegrationTest
  test "a Surf application gets a public board and stays hidden until allowlisted" do
    user = create_user
    host! "surf.soda.fan"
    post "/api/v1/groups", params: {group: {nickname: "测试群组"}}, headers: auth_headers(user)
    assert_response :created
    group = Group.find(json_response.fetch("id"))
    assert_equal "pending", group.review_status
    assert group.discussion_enabled?
    assert_equal "everyone", group.can_post_topic
    assert group.categories.listed.exists?(visibility: "public")
    get "/api/v1/groups/#{group.id}", headers: auth_headers(user)
    assert_response :not_found
  end
end
