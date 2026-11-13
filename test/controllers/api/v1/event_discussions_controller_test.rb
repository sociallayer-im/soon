require "test_helper"

class Api::V1::EventDiscussionsControllerTest < ActionDispatch::IntegrationTest
  include ContentSafetyTestGateway
  setup do
    @previous_gate = ENV["DISCUSSION_ENABLED"]
    ENV["DISCUSSION_ENABLED"] = "true"
    @owner = create_user
    @group = create_group(owner: @owner, discussion_enabled: true)
    @category = create_category(group: @group)
    @event = create_event(group: @group, owner: @owner, status: "published")
  end

  teardown { ENV["DISCUSSION_ENABLED"] = @previous_gate }

  test "newest discussion sorting precedes pagination and preserves default activity order" do
    older = create_topic(category: @category, user: @owner, event_id: @event.id, created_at: 2.days.ago)
    newer = create_topic(category: @category, user: @owner, event_id: @event.id, created_at: 1.day.ago)
    older.update_columns(last_active_mark: Time.current.to_i)
    newer.update_columns(last_active_mark: 1)
    get "/api/v1/events/#{@event.id}/discussion", params: {sort: "newest", limit: 1}
    assert_response :success
    assert_equal [newer.id], json_response["data"].pluck("id")
    get "/api/v1/events/#{@event.id}/discussion", params: {sort: "newest", limit: 1, page: 2}
    assert_response :success
    assert_equal [older.id], json_response["data"].pluck("id")
    get "/api/v1/events/#{@event.id}/discussion", params: {limit: 1}
    assert_equal [older.id], json_response["data"].pluck("id")
  end

  test "newest cursor excludes newly inserted discussions from subsequent pages" do
    older = create_topic(category: @category, user: @owner, event_id: @event.id, created_at: 2.days.ago)
    newer = create_topic(category: @category, user: @owner, event_id: @event.id, created_at: 1.day.ago)
    get "/api/v1/events/#{@event.id}/discussion", params: {sort: "newest", limit: 1, cursor: "start"}
    assert_response :success
    assert_equal newer.id, json_response["data"].first["id"]
    cursor = json_response["meta"]["next_cursor"]
    create_topic(category: @category, user: @owner, event_id: @event.id)
    get "/api/v1/events/#{@event.id}/discussion", params: {sort: "newest", limit: 1, cursor: cursor}
    assert_response :success
    assert_equal older.id, json_response["data"].first["id"]
    assert_nil json_response["meta"]["next_cursor"]
  end

  test "linked post can be edited and deleted by its author while strangers are denied" do
    post "/api/v1/events/#{@event.id}/discussion",params:{discussion:{content:"原内容",title:"原标题",sync_to_community:true}},headers:auth_headers(@owner),as: :json
    assert_response :created
    id=json_response["id"]
    stranger=create_user
    patch "/api/v1/topics/#{id}",params:{topic:{title:"不允许"}},headers:auth_headers(stranger),as: :json
    assert_response :forbidden
    delete "/api/v1/topics/#{id}",headers:auth_headers(stranger)
    assert_response :forbidden
    patch "/api/v1/topics/#{id}",params:{topic:{title:"新标题",content:"新内容",image_url:""}},headers:auth_headers(@owner),as: :json
    assert_response :success
    assert_equal @event.id,json_response["event_id"]
    assert_equal "新内容",json_response["content"]
    delete "/api/v1/topics/#{id}",headers:auth_headers(@owner)
    assert_response :success
    get "/api/v1/events/#{@event.id}/discussion",headers:auth_headers(@owner)
    assert_response :success
    assert_not_includes json_response["data"].map { |topic| topic["id"] },id
  end

  test "associated posts share a topic and local discussions stay out of community" do
    post "/api/v1/events/#{@event.id}/discussion", params: {discussion: {content: "活动后的分享", sync_to_community: true}}, headers: auth_headers(@owner), as: :json
    assert_response :created
    shared = json_response["id"]
    assert_equal @event.id, json_response["event_id"]
    get "/api/v1/events/#{@event.id}/discussion"
    assert_response :success
    assert_includes json_response["data"].map { |t| t["id"] }, shared
    post "/api/v1/events/#{@event.id}/discussion", params: {discussion: {content: "仅活动内讨论", sync_to_community: false}}, headers: auth_headers(@owner), as: :json
    assert_response :created
    local = json_response["id"]
    get "/api/v1/topics", params: {group_id: @group.id}
    assert_includes json_response["data"].map { |t| t["id"] }, shared
    refute_includes json_response["data"].map { |t| t["id"] }, local
  end

  test "disabled group and posting permissions cannot be bypassed by association" do
    @group.update!(can_post_topic: "manager")
    post "/api/v1/events/#{@event.id}/discussion", params: {discussion: {content: "拒绝发布"}}, headers: auth_headers(create_user), as: :json
    assert_response :unprocessable_entity
    assert_equal 0, Topic.where(event_id: @event.id).count
    @group.update!(discussion_enabled: false)
    get "/api/v1/events/#{@event.id}/discussion"
    assert_response :not_found
  end
end
