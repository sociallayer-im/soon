require "test_helper"

class Api::V1::CommentsControllerTest < ActionDispatch::IntegrationTest
  test "create requires authentication" do
    post "/api/v1/comments", params: { comment: { comment_type: "comment", content: "hi" } }
    assert_response :unauthorized
  end

  %w[checkin chat comment star feedback].each do |type|
    test "create accepts comment_type=#{type}" do
      user = create_user
      group = create_group(owner: user)

      post "/api/v1/comments", params: {
        comment: { item_type: "Group", item_id: group.id, comment_type: type, content: "hello" }
      }, headers: auth_headers(user)
      assert_response :created
      assert_equal type, json_response["comment_type"]
    end
  end

  test "create rejects an invalid comment_type" do
    user = create_user
    post "/api/v1/comments", params: {
      comment: { comment_type: "bogus", content: "hi" }
    }, headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "create attaches the polymorphic item correctly" do
    user = create_user
    group = create_group(owner: user)

    post "/api/v1/comments", params: {
      comment: { item_type: "Group", item_id: group.id, comment_type: "comment", content: "nice group" }
    }, headers: auth_headers(user)
    assert_response :created

    comment = Comment.find(json_response["id"])
    assert_equal group, comment.item
    assert_equal user, comment.user
    assert_equal "Group", json_response["item_type"]
    assert_equal group.id, json_response["item_id"]
  end

  test "star is idempotent — does not create duplicate rows" do
    user = create_user
    group = create_group(owner: user)

    assert_difference "Comment.count", 1 do
      post "/api/v1/comments/star", params: { item_type: "Group", item_id: group.id }, headers: auth_headers(user)
      assert_response :success
      post "/api/v1/comments/star", params: { item_type: "Group", item_id: group.id }, headers: auth_headers(user)
      assert_response :success
    end

    star = Comment.find_by(user: user, item_type: "Group", item_id: group.id, comment_type: "star")
    assert star.present?
    assert_nil star.content
  end

  test "unstar removes the star row" do
    user = create_user
    group = create_group(owner: user)
    post "/api/v1/comments/star", params: { item_type: "Group", item_id: group.id }, headers: auth_headers(user)

    assert_difference "Comment.count", -1 do
      post "/api/v1/comments/unstar", params: { item_type: "Group", item_id: group.id }, headers: auth_headers(user)
      assert_response :success
    end
    assert_not Comment.exists?(user: user, item_type: "Group", item_id: group.id, comment_type: "star")
  end

  test "unstar when no star exists does not error" do
    user = create_user
    group = create_group(owner: user)

    assert_no_difference "Comment.count" do
      post "/api/v1/comments/unstar", params: { item_type: "Group", item_id: group.id }, headers: auth_headers(user)
    end
    assert_response :success
  end

  test "remove is author-only" do
    author = create_user
    other = create_user
    group = create_group(owner: author)
    comment = create_comment(user: author, item: group)

    post "/api/v1/comments/#{comment.id}/remove", headers: auth_headers(other)
    assert_response :forbidden
    assert_not comment.reload.removed
  end

  test "remove soft-deletes the comment (removed: true, row still exists)" do
    author = create_user
    group = create_group(owner: author)
    comment = create_comment(user: author, item: group)

    post "/api/v1/comments/#{comment.id}/remove", headers: auth_headers(author)
    assert_response :success
    assert_equal "ok", json_response["result"]

    reloaded = Comment.find(comment.id)
    assert reloaded.removed
  end

  test "remove 404s for an unknown comment id" do
    user = create_user
    post "/api/v1/comments/does-not-exist/remove", headers: auth_headers(user)
    assert_response :not_found
  end

  test "index filters by comment_type" do
    user = create_user
    group = create_group(owner: user)
    comment = create_comment(user: user, item: group, comment_type: "comment")
    create_comment(user: user, item: group, comment_type: "chat")

    get "/api/v1/comments", params: { comment_type: "comment" }, headers: auth_headers(user)
    assert_response :success
    ids = json_response["data"].map { |c| c["id"] }
    assert_equal [comment.id], ids
  end

  test "index filters by item_type/item_id" do
    user = create_user
    group1 = create_group(owner: user)
    group2 = create_group(owner: user)
    c1 = create_comment(user: user, item: group1, comment_type: "comment")
    create_comment(user: user, item: group2, comment_type: "comment")

    get "/api/v1/comments", params: { comment_type: "comment", item_type: "Group", item_id: group1.id },
      headers: auth_headers(user)
    ids = json_response["data"].map { |c| c["id"] }
    assert_equal [c1.id], ids
  end

  test "index filters by user_id" do
    user1 = create_user
    user2 = create_user
    group = create_group(owner: user1)
    c1 = create_comment(user: user1, item: group, comment_type: "comment")
    create_comment(user: user2, item: group, comment_type: "comment")

    get "/api/v1/comments", params: { comment_type: "comment", user_id: user1.id }, headers: auth_headers(user1)
    ids = json_response["data"].map { |c| c["id"] }
    assert_equal [c1.id], ids
  end

  test "index excludes removed comments via the visible scope" do
    user = create_user
    group = create_group(owner: user)
    visible = create_comment(user: user, item: group, comment_type: "comment")
    removed = create_comment(user: user, item: group, comment_type: "comment", removed: true)

    get "/api/v1/comments", params: { comment_type: "comment" }, headers: auth_headers(user)
    ids = json_response["data"].map { |c| c["id"] }
    assert_includes ids, visible.id
    assert_not_includes ids, removed.id
  end

  test "index is public" do
    get "/api/v1/comments", params: { comment_type: "comment" }
    assert_response :success
  end
end
