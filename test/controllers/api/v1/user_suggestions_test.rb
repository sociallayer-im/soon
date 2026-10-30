require "test_helper"
class Api::V1::UserSuggestionsTest < ActionDispatch::IntegrationTest
  setup do
    @host = create_user(data: {city: "上海"})
    @group = create_group(owner: @host, city: "上海")
    @event = create_event(group: @group, owner: @host, start_time: 1.day.from_now, end_time: 2.days.from_now,
                          status: "published", visibility: "normal")
  end
  test "role candidates require authentication and expose only public profiles" do
    get "/api/v1/users/role_candidates"
    assert_response :unauthorized
    get "/api/v1/users/role_candidates", headers: auth_headers(@host)
    assert_response :success
    row = response.parsed_body["data"].find { |u| u["id"] == @host.id }
    assert row
    assert_not row.key?("phone")
    assert_not row.key?("email")
    @event.update!(visibility: "unlisted")
    get "/api/v1/users/role_candidates", headers: auth_headers(@host)
    assert_empty response.parsed_body["data"]
  end

  test "anonymous discovery is paginated and exposes only discovery fields" do
    get "/api/v1/users/suggestions", params: {city: "上海", limit: 1}
    assert_response :success
    row = response.parsed_body["data"].first
    assert_equal @host.id, row["id"]
    assert_equal "同城活动发起人", row["recommendation_reason"]
    assert_equal %w[id name nickname image_url bio city recommendation_reason].sort, row.keys.sort
    assert response.parsed_body["meta"].key?("next_page")
    get "/api/v1/users/suggestions", params: {city: "杭州"}
    assert_empty response.parsed_body["data"]
  end
  test "self and followed users are excluded only for the authenticated caller" do
    get "/api/v1/users/suggestions", headers: auth_headers(@host)
    assert_empty response.parsed_body["data"]
    viewer = create_user
    Follow.create!(user: viewer, target: @host, status: "active")
    get "/api/v1/users/suggestions", headers: auth_headers(viewer)
    assert_empty response.parsed_body["data"]
    get "/api/v1/users/suggestions"
    assert_equal [@host.id], response.parsed_body["data"].map { |r| r["id"] }
  end
  test "hidden inactive draft unlisted and past hosts are not discovery candidates" do
    [{status: "draft"}, {visibility: "unlisted"}, {end_time: 1.day.ago, start_time: 2.days.ago}].each do |attrs|
      @event.update!(attrs)
      get "/api/v1/users/suggestions"
      assert_empty response.parsed_body["data"]
      @event.update!(status: "published", visibility: "normal", start_time: 1.day.from_now, end_time: 2.days.from_now)
    end
    @host.update!(data: {visibility: "private"})
    get "/api/v1/users/suggestions"
    assert_empty response.parsed_body["data"]
    @host.update!(data: {}, active: false)
    get "/api/v1/users/suggestions"
    assert_empty response.parsed_body["data"]
  end
end
