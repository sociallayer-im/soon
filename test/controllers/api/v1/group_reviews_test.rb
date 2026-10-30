require "test_helper"

class Api::V1::GroupReviewsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = create_user
    @admin = create_user(admin: true)
    @group = create_group(owner: @owner, active: false, review_status: "pending")
  end

  test "creation is pending regardless of submitted approval fields" do
    post "/api/v1/groups", params: {group: {name: "review-#{unique_suffix}", active: true, review_status: "approved"}}, headers: auth_headers(@owner)
    assert_response :created
    assert_equal "pending", json_response["review_status"]
    assert_not Group.find(json_response["id"]).active
    get "/api/v1/groups/#{json_response["id"]}", headers: auth_headers(@owner)
    assert_response :success
  end

  test "only platform administrators can review and list applications" do
    get "/api/v1/admin/group_reviews", headers: auth_headers(@owner)
    assert_response :forbidden
    post "/api/v1/admin/group_reviews/#{@group.id}/review", params: {decision: "approved"}, headers: auth_headers(@owner)
    assert_response :forbidden
    assert_equal "pending", @group.reload.review_status
    get "/api/v1/admin/group_reviews", headers: auth_headers(@admin)
    assert_response :success
    assert_includes json_response["data"].map { |g| g["id"] }, @group.id
  end

  test "approval activates group and cannot be replayed" do
    get "/api/v1/groups/directory"
    assert_not_includes json_response["data"].map { |g| g["id"] }, @group.id
    get "/api/v1/groups/#{@group.id}"
    assert_response :not_found
    get "/api/v1/groups/#{@group.id}", headers: auth_headers(@owner)
    assert_response :success
    post "/api/v1/admin/group_reviews/#{@group.id}/review", params: {decision: "approved"}, headers: auth_headers(@admin)
    assert_response :success
    assert @group.reload.active
    assert_equal @admin.id, @group.reviewed_by_id
    assert @group.reviewed_at
    post "/api/v1/admin/group_reviews/#{@group.id}/review", params: {decision: "rejected",reason:"重复"}, headers: auth_headers(@admin)
    assert_response :conflict
    assert_equal "approved", @group.reload.review_status
  end

  test "rejection requires reason and keeps group inactive; owner cannot bypass" do
    post "/api/v1/admin/group_reviews/#{@group.id}/review", params: {decision: "rejected"}, headers: auth_headers(@admin)
    assert_response :unprocessable_entity
    post "/api/v1/admin/group_reviews/#{@group.id}/review", params: {decision: "rejected",reason:"请补充介绍"}, headers: auth_headers(@admin)
    assert_response :success
    assert_equal "请补充介绍", @group.reload.review_reason
    assert_not @group.active
    patch "/api/v1/groups/#{@group.id}", params: {group: {active:true,review_status:"approved",bio:"updated"}}, headers: auth_headers(@owner)
    assert_response :success
    assert_equal "rejected", @group.reload.review_status
    assert_not @group.active
  end

  test "pending groups cannot publish events or topics" do
    event = Event.new(group: @group,owner: @owner)
    assert_not EventPolicy.new(@owner,event).create?
    topic = Topic.new(group: @group)
    assert_not TopicPolicy.new(@owner,topic).create?
  end
end
