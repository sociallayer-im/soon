require "test_helper"

class Api::V1::CampaignReviewsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = create_user
    @admin = create_user(admin: true)
    @outsider = create_user
    @group = create_group(owner: @owner, city: "上海")
    @event = create_event(group: @group, owner: @owner, status: "published", visibility: "normal")
  end

  def submit
    post "/api/v1/campaigns", params: {campaign: {group_id: @group.id, title: "新的专题", introduction: "一起参与", status: "published", review_status: "approved", event_ids: [@event.id]}, idempotency_key: "campaign_review_test_123"}, headers: auth_headers(@owner), as: :json
    assert_response :created
    Campaign.find(json_response["id"])
  end

  def review(campaign, decision, actor: @admin, reason: "")
    post "/api/v1/admin/campaign_reviews/#{campaign.id}/review", params: {decision: decision, reason: reason}, headers: auth_headers(actor), as: :json
  end

  test "submission cannot bypass review, is private, is idempotent, and appears in admin tasks" do
    campaign = submit
    assert_equal "pending", campaign.review_status
    assert_equal campaign.id, submit.id
    assert_equal 1, Campaign.count
    get "/api/v1/campaigns"
    assert_empty json_response["data"]
    get "/api/v1/campaigns/#{campaign.id}", headers: auth_headers(@outsider)
    assert_response :forbidden
    get "/api/v1/campaigns", params: {mine: true}, headers: auth_headers(@owner)
    assert_equal [campaign.id], json_response["data"].map { |c| c["id"] }
    assert SiteNotificationTasks.for(@admin).any? { |task| task[:kind] == "campaign_review" && task[:resource_id] == campaign.id }
    assert_not SiteNotificationTasks.for(@owner).any? { |task| task[:kind] == "campaign_review" }
    get "/api/v1/discovery/home", params: {city: "上海"}
    assert_not (json_response["campaigns"] || []).any? { |c| c["id"] == campaign.id }
  end

  test "only superadmins review and approve once, notify owner and publish" do
    campaign = submit
    review(campaign, "approved", actor: @owner)
    assert_response :forbidden
    assert_equal "pending", campaign.reload.review_status
    review(campaign, "approved")
    assert_response :success
    assert_equal @admin.id, campaign.reload.reviewed_by_id
    assert_equal 1, campaign.campaign_review_logs.count
    get "/api/v1/campaigns/#{campaign.id}"
    assert_response :success
    assert_not SiteNotificationTasks.for(@admin).any? { |task| task[:resource_id] == campaign.id && task[:kind] == "campaign_review" }
    notice = Activity.find_by(receiver: @owner, item: campaign, action: "surf/campaign_review_result")
    assert notice
    assert_equal({page: "campaign-detail", id: campaign.id}, SiteNotifications.target(notice, @owner))
    review(campaign, "rejected", reason: "再次处理")
    assert_response :conflict
    assert_equal "approved", campaign.reload.review_status
  end

  test "rejection requires a reason and an edit resubmits instead of bypassing review" do
    campaign = submit
    review(campaign, "rejected")
    assert_response :unprocessable_entity
    review(campaign, "rejected", reason: "请补充介绍")
    assert_response :success
    assert_equal "请补充介绍", campaign.reload.review_reason
    get "/api/v1/campaigns/#{campaign.id}"
    assert_response :forbidden
    patch "/api/v1/campaigns/#{campaign.id}", params: {campaign: {introduction: "补充后的介绍", status: "published", review_status: "approved"}}, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal "pending", campaign.reload.review_status
    assert_nil campaign.review_reason
    assert_equal %w[rejected resubmitted], campaign.campaign_review_logs.order(:created_at).pluck(:decision)
    review(campaign, "approved")
    assert_response :success
    patch "/api/v1/campaigns/#{campaign.id}", params: {campaign: {title: "修改已公开专题"}}, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal "pending", campaign.reload.review_status
    get "/api/v1/campaigns/#{campaign.id}"
    assert_response :forbidden
  end

  test "approval revalidates events and group and failed edits do not change published state" do
    campaign = submit
    @event.update!(visibility: "unlisted")
    review(campaign, "approved")
    assert_response :unprocessable_entity
    assert_equal "pending", campaign.reload.review_status
    assert_equal 0, campaign.campaign_review_logs.count
    @event.update!(visibility: "normal")
    @group.update!(active: false)
    review(campaign, "approved")
    assert_response :unprocessable_entity
    @group.update!(active: true)
    review(campaign, "approved")
    assert_response :success
    patch "/api/v1/campaigns/#{campaign.id}", params: {campaign: {event_ids: ["missing"]}}, headers: auth_headers(@owner), as: :json
    assert_response :unprocessable_entity
    assert_equal "approved", campaign.reload.review_status
  end
end
