require "test_helper"

class Api::V1::CommunityProjectsControllerTest < ActionDispatch::IntegrationTest
  test "publishing, accepting an invitation and moderating comments respect community permissions" do
    manager = create_user
    author = create_user
    participant = create_user
    visitor = create_user
    group = create_group(owner: manager, community_projects_enabled: true)
    create_membership(user: author, group: group)
    create_membership(user: participant, group: group)
    collection = "/api/v1/groups/#{group.id}/community_projects"
    fields = { title: "Community tool", tagline: "A short introduction", content: "Project description",
      icon_url: "https://example.com/icon.png", cover_url: "https://example.com/cover.png",
      gallery: [{ url: "https://example.com/product.png", caption: "Preview" }] }

    post collection, params: { project: fields }, headers: auth_headers(visitor), as: :json
    assert_response :forbidden
    post collection, params: { project: fields }, headers: auth_headers(author), as: :json
    assert_response :created
    path = "#{collection}/#{JSON.parse(response.body).fetch("id")}"
    get path
    assert_response :not_found

    patch path, params: { project: { status: "published" } }, headers: auth_headers(author), as: :json
    assert_response :ok
    assert_equal fields[:gallery].first[:url], JSON.parse(response.body).dig("gallery", 0, "url")
    post "#{path}/invite", params: { username: participant.name, role: "Design" }, headers: auth_headers(author), as: :json
    assert_response :created
    member_id = JSON.parse(response.body).fetch("id")
    get path
    assert_empty JSON.parse(response.body).fetch("members")
    post "#{path}/members/#{member_id}/accept", headers: auth_headers(participant)
    assert_response :no_content
    get path
    assert_equal participant.name, JSON.parse(response.body).dig("members", 0, "user", "name")

    post "#{path}/comments", params: { content: "Looks good!" }, headers: auth_headers(visitor), as: :json
    assert_response :forbidden
    post "#{path}/comments", params: { content: "Looks good!" }, headers: auth_headers(participant), as: :json
    assert_response :created
    comment_id = JSON.parse(response.body).fetch("id")
    get "#{path}/comments"
    assert_equal ["Looks good!"], JSON.parse(response.body).fetch("data").pluck("content")
    delete "#{path}/comments/#{comment_id}", headers: auth_headers(manager)
    assert_response :no_content

    post "#{path}/hide", headers: auth_headers(manager)
    assert_response :no_content
    get path
    assert_response :not_found
    get "#{path}/comments"
    assert_response :not_found
  end
end
