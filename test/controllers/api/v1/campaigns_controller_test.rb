require "test_helper"

class Api::V1::CampaignsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = create_user
    @group = create_group(owner: @owner, city: "杭州")
    @event = create_event(group: @group, owner: @owner, status: "published", visibility: "normal")
  end

  def create_campaign(approve: true, **attrs)
    post "/api/v1/campaigns", params: { campaign: { group_id: @group.id, title: "城市共读", introduction: "每周相聚", status: "published", event_ids: [@event.id] }.merge(attrs) }, headers: auth_headers(@owner), as: :json
    Campaign.find(json_response["id"]).update!(review_status: "approved") if approve && response.status == 201 && attrs[:status] != "draft"
  end

  test "create series with ordered cross-city events and media then browse it publicly" do
    other = create_event(group: create_group(city: "上海"), owner: create_user, status: "published", visibility: "normal")
    create_campaign(event_ids: [other.id, @event.id, other.id], media: [{ type: "image", url: "https://example.com/cover.jpg" }])
    assert_response :created
    id = json_response["id"]
    assert_equal [other.id, @event.id], json_response["event_ids"]
    assert_equal "https://example.com/cover.jpg", json_response["cover_url"]
    get "/api/v1/campaigns/#{id}"
    assert_response :success
    assert_equal ["上海", "杭州"], json_response["cities"]
    assert_equal false, json_response["can_edit"]
    get "/api/v1/campaigns", params: { city: "上海" }
    assert_equal [id], json_response["data"].map { |c| c["id"] }
    get "/api/v1/events", params: { campaign_id: id }
    assert_equal [other.id, @event.id].sort, json_response["data"].map { |e| e["id"] }.sort
  end

  test "non-manager cannot create or change another campaign" do
    outsider = create_user
    post "/api/v1/campaigns", params: { campaign: { group_id: @group.id, title: "Test" } }, headers: auth_headers(outsider), as: :json
    assert_response :forbidden
    create_campaign
    id = json_response["id"]
    patch "/api/v1/campaigns/#{id}", params: { campaign: { title: "Stolen" } }, headers: auth_headers(outsider), as: :json
    assert_response :forbidden
  end

  test "draft privacy and atomic rejection of invalid replacement" do
    create_campaign(status: "draft")
    id = json_response["id"]
    get "/api/v1/campaigns/#{id}"
    assert_response :forbidden
    get "/api/v1/campaigns"
    assert_empty json_response["data"]
    patch "/api/v1/campaigns/#{id}", params: { campaign: { title: "Changed", event_ids: ["missing"] } }, headers: auth_headers(@owner), as: :json
    assert_response :unprocessable_entity
    assert_equal "城市共读", Campaign.find(id).title
    assert_equal [@event.id], Campaign.find(id).event_ids
    patch "/api/v1/campaigns/#{id}", params: { campaign: { event_ids: [] } }, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_empty Campaign.find(id).event_ids
  end

  test "publication rejects empty series and non-public events and unsafe images" do
    create_campaign(event_ids: [])
    assert_response :unprocessable_entity
    @event.update!(visibility: "unlisted")
    create_campaign
    assert_response :unprocessable_entity
    @event.update!(visibility: "normal")
    create_campaign(media: [{ type: "image", url: "javascript:alert(1)" }])
    assert_response :unprocessable_entity
  end

  test "removing series preserves its events and removing event clears membership" do
    create_campaign
    id = json_response["id"]
    delete "/api/v1/campaigns/#{id}", headers: auth_headers(@owner)
    assert_response :no_content
    assert Event.exists?(@event.id)
    create_campaign
    @event.destroy!
    assert_equal 0, CampaignEvent.count
  end

  test "group city is editable normalized discoverable and filterable" do
    patch "/api/v1/groups/#{@group.id}", params: { group: { city: " 北京 " } }, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal "北京", json_response["city"]
    create_group(city: "上海", active: false)
    get "/api/v1/cities"
    assert_includes json_response["data"], "北京"
    assert_not_includes json_response["data"], "上海"
    get "/api/v1/groups/directory", params: { city: "北京" }
    assert_equal [@group.id], json_response["data"].map { |g| g["id"] }
    get "/api/v1/events", params: { city: "北京" }, headers: auth_headers(create_user)
    assert_equal [@event.id], json_response["data"].map { |e| e["id"] }
  end
  test "metadata edits preserve associations and cannot transfer the group" do
    create_campaign
    id = json_response["id"]
    patch "/api/v1/campaigns/#{id}", params: { campaign: { title: "New title", group_id: create_group.id } }, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal @group.id, json_response["group_id"]
    assert_equal [@event.id], json_response["event_ids"]
    Campaign.find(id).update!(review_status: "approved")
    @event.update!(status: "draft")
    get "/api/v1/campaigns/#{id}"
    assert_response :success
    assert_empty json_response["event_ids"]
    assert_empty json_response["cities"]
    get "/api/v1/campaigns", params: { city: "杭州" }
    assert_empty json_response["data"]
  end

  test "anonymous writes require login and unrelated hidden events cannot be linked" do
    post "/api/v1/campaigns", params: { campaign: { title: "test" } }, as: :json
    assert_response :unauthorized
    hidden = create_event(group: create_group, owner: create_user, status: "draft")
    create_campaign(status: "draft", event_ids: [hidden.id])
    assert_response :unprocessable_entity
    create_campaign(status: "draft", event_ids: [])
    assert_response :created
  end

  test "positions explicitly reorder associations and survive legacy saves" do
    other = create_event(group: @group, owner: @owner, status: "published", visibility: "normal")
    create_campaign(event_ids: [@event.id, other.id], positions: [other.id, @event.id])
    assert_response :created
    id = json_response["id"]
    assert_equal [other.id, @event.id], json_response["positions"]
    assert_equal [other.id, @event.id], Campaign.find(id).positions
    assert_equal [other.id, @event.id], Campaign.find(id).event_ids
    patch "/api/v1/campaigns/#{id}", params: {campaign: {positions: [@event.id, other.id]}}, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal [@event.id, other.id], json_response["event_ids"]
    assert_equal [@event.id, other.id], Campaign.find(id).positions
    patch "/api/v1/campaigns/#{id}", params: {campaign: {event_ids: [@event.id, other.id]}}, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal [@event.id, other.id], Campaign.find(id).positions
    patch "/api/v1/campaigns/#{id}", params: {campaign: {title: "新名称"}}, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal [@event.id, other.id], Campaign.find(id).positions
  end

  test "invalid positions fail atomically without changing review state" do
    create_campaign
    id = json_response["id"]
    [[@event.id, @event.id], [], ["missing"], "invalid"].each do |positions|
      patch "/api/v1/campaigns/#{id}", params: {campaign: {positions: positions, title: "错误更新"}}, headers: auth_headers(@owner), as: :json
      assert_response :unprocessable_entity
      campaign = Campaign.find(id)
      assert_equal "城市共读", campaign.title
      assert_equal "approved", campaign.review_status
      assert_equal [@event.id], campaign.positions
      assert_equal [@event.id], campaign.event_ids
    end
  end

  test "deleting an event removes its stored position and hidden events are never exposed" do
    other = create_event(group: @group, owner: @owner, status: "published", visibility: "normal")
    create_campaign(event_ids: [@event.id, other.id])
    id = json_response["id"]
    other.update!(visibility: "unlisted")
    get "/api/v1/campaigns/#{id}"
    assert_response :success
    assert_equal [@event.id], json_response["positions"]
    other.destroy!
    assert_equal [@event.id], Campaign.find(id).positions
  end

end
