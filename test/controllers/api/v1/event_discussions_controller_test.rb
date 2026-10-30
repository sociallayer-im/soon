require "test_helper"

class Api::V1::EventDiscussionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_gate = ENV["DISCUSSION_ENABLED"]
    ENV["DISCUSSION_ENABLED"] = "true"
    @owner = create_user
    @group = create_group(owner: @owner, discussion_enabled: true)
    @category = create_category(group: @group)
    @event = create_event(group: @group, owner: @owner, status: "published")
  end

  teardown { ENV["DISCUSSION_ENABLED"] = @previous_gate }

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
