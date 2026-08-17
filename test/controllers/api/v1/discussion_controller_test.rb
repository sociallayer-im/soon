require "test_helper"

# The endpoints, including the two gates that turn the whole feature off and
# every read path a private board could leak through.
class Api::V1::DiscussionControllerTest < ActionDispatch::IntegrationTest
  def setup
    @owner = create_user
    @author = create_user
    @stranger = create_user
    @group = create_group(owner: @owner, discussion_enabled: true)
    @category = create_category(group: @group)
  end

  # Everything in this file runs with the deployment gate open; the one test
  # below that checks the gate itself closes it deliberately.
  def with_discussion(&block)
    ENV["DISCUSSION_ENABLED"] = "true"
    yield
  ensure
    ENV.delete("DISCUSSION_ENABLED")
  end

  test "every discussion endpoint 404s when the deployment gate is closed" do
    topic = with_discussion { create_topic(category: @category, user: @author) }

    ENV.delete("DISCUSSION_ENABLED")
    get "/api/v1/categories", params: { group_id: @group.id }
    assert_response :not_found
    get "/api/v1/topics", params: { group_id: @group.id }
    assert_response :not_found
    get "/api/v1/topics/#{topic.id}"
    assert_response :not_found
    get "/api/v1/topics/#{topic.id}/replies"
    assert_response :not_found
    post "/api/v1/topics", params: { topic: { category_id: @category.id, title: "x" } },
         headers: auth_headers(@author)
    assert_response :not_found
  end

  test "a group with discussion off 404s even when the deployment gate is open" do
    with_discussion do
      off = create_group(owner: @owner)
      get "/api/v1/topics", params: { group_id: off.id }
      assert_response :not_found
      get "/api/v1/categories", params: { group_id: off.id }
      assert_response :not_found
    end
  end

  # Regression: the group switch was only checked on the two endpoints that
  # take ?group_id=. Everything addressed by record id ignored it, so a group
  # that turned its forum off kept every existing topic readable, editable and
  # deletable by anyone who had the URL.
  test "turning a group's forum off closes every endpoint, not just the lists" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)
      reply = create_reply(topic: topic, user: @author)
      @group.update!(discussion_enabled: false)

      get "/api/v1/topics", params: { group_id: @group.id }
      assert_response :not_found
      get "/api/v1/categories", params: { group_id: @group.id }
      assert_response :not_found
      get "/api/v1/topics/#{topic.id}"
      assert_response :not_found
      get "/api/v1/topics/#{topic.id}/replies"
      assert_response :not_found
      post "/api/v1/topics/#{topic.id}/replies", params: { reply: { content: "x" } },
           headers: auth_headers(@author)
      assert_response :not_found
      patch "/api/v1/topics/#{topic.id}", params: { topic: { title: "changed" } },
            headers: auth_headers(@author)
      assert_response :not_found
      delete "/api/v1/topics/#{topic.id}", headers: auth_headers(@author)
      assert_response :not_found
      post "/api/v1/topics/#{topic.id}/pin", headers: auth_headers(@owner)
      assert_response :not_found
      patch "/api/v1/replies/#{reply.id}", params: { reply: { content: "y" } },
            headers: auth_headers(@author)
      assert_response :not_found
      delete "/api/v1/replies/#{reply.id}", headers: auth_headers(@author)
      assert_response :not_found
      patch "/api/v1/categories/#{@category.id}", params: { category: { name: "N" } },
            headers: auth_headers(@owner)
      assert_response :not_found
    end
  end

  # Regression: can_edit used to build a policy per reply, which asked the
  # memberships table once per floor. The manager half of that answer is the
  # same for the whole thread.
  test "the reply list does not query per reply" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)
      3.times { create_reply(topic: topic, user: create_user) }
      few = count_queries { get "/api/v1/topics/#{topic.id}/replies", headers: auth_headers(@stranger) }
      12.times { create_reply(topic: topic, user: create_user) }
      many = count_queries { get "/api/v1/topics/#{topic.id}/replies", headers: auth_headers(@stranger) }

      assert_equal few, many,
        "reply list went from #{few} to #{many} queries when the thread grew from 3 to 15 replies"
    end
  end

  test "search treats LIKE metacharacters as text" do
    with_discussion do
      create_topic(category: @category, user: @author, title: "alpha")
      create_topic(category: @category, user: @author, title: "100% cotton")

      # A bare "%" used to return the whole board as if every title matched.
      get "/api/v1/topics", params: { group_id: @group.id, search: "%" }
      assert_equal [ "100% cotton" ], json_response["data"].map { |t| t["title"] }

      get "/api/v1/topics", params: { group_id: @group.id, search: "_" }
      assert_empty json_response["data"]

      get "/api/v1/topics", params: { group_id: @group.id, search: "alpha" }
      assert_equal [ "alpha" ], json_response["data"].map { |t| t["title"] }
    end
  end

  def count_queries
    n = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      n += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
    end
    yield
    n
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  test "reads are public and do not 401 without a token" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)
      create_reply(topic: topic, user: @author)

      get "/api/v1/categories", params: { group_id: @group.id }
      assert_response :success
      get "/api/v1/topics", params: { group_id: @group.id }
      assert_response :success
      get "/api/v1/topics/#{topic.id}"
      assert_response :success
      get "/api/v1/topics/#{topic.id}/replies"
      assert_response :success
    end
  end

  test "posting a topic and replying to it" do
    with_discussion do
      # can_post_topic defaults to "member", so both need to have joined.
      create_membership(user: @author, group: @group)
      create_membership(user: @stranger, group: @group)

      post "/api/v1/topics",
           params: { topic: { category_id: @category.id, title: "Hello", content: "Body" } },
           headers: auth_headers(@author)
      assert_response :created
      topic_id = json_response["id"]

      post "/api/v1/topics/#{topic_id}/replies",
           params: { reply: { content: "First" } },
           headers: auth_headers(@stranger)
      assert_response :created

      get "/api/v1/topics/#{topic_id}"
      assert_response :success
      assert_equal 1, json_response["replies_count"]
    end
  end

  test "a private board and its topics are invisible, as 404 rather than 403" do
    with_discussion do
      board = create_category(group: @group, visibility: "member")
      topic = create_topic(category: board, user: @owner)
      reply = create_reply(topic: topic, user: @owner)

      # The board itself
      get "/api/v1/categories", params: { group_id: @group.id },
          headers: auth_headers(@stranger)
      assert_not_includes json_response["data"].map { |c| c["id"] }, board.id

      # The list
      get "/api/v1/topics", params: { group_id: @group.id }, headers: auth_headers(@stranger)
      assert_not_includes json_response["data"].map { |t| t["id"] }, topic.id

      # Straight at the id — the path that bypasses the list
      get "/api/v1/topics/#{topic.id}", headers: auth_headers(@stranger)
      assert_response :not_found

      # The floors
      get "/api/v1/topics/#{topic.id}/replies", headers: auth_headers(@stranger)
      assert_response :not_found

      # Search, author filter, and the starred list all run through the same
      # scope; each is its own chance to forget it.
      get "/api/v1/topics", params: { group_id: @group.id, search: topic.title },
          headers: auth_headers(@stranger)
      assert_empty json_response["data"]

      get "/api/v1/topics", params: { group_id: @group.id, user_id: @owner.id },
          headers: auth_headers(@stranger)
      assert_not_includes json_response["data"].map { |t| t["id"] }, topic.id

      Comment.create!(user: @stranger, item_type: "Topic", item_id: topic.id,
                      comment_type: "star")
      get "/api/v1/topics", params: { group_id: @group.id, starred_id: @stranger.id },
          headers: auth_headers(@stranger)
      assert_empty json_response["data"]

      # A member does see all of it.
      create_membership(user: @stranger, group: @group)
      get "/api/v1/topics/#{topic.id}", headers: auth_headers(@stranger)
      assert_response :success
      assert_equal reply.topic_id, topic.id
    end
  end

  test "losing a team hides that team's board immediately" do
    with_discussion do
      create_membership(user: @stranger, group: @group)
      board = create_category(group: @group, visibility: "team")
      topic = create_topic(category: board, user: @owner)
      team = create_team(group: @group, users: [ @stranger ])
      CategoryTeam.create!(category: board, team: team)
      Comment.create!(user: @stranger, item_type: "Topic", item_id: topic.id,
                      comment_type: "star")

      get "/api/v1/topics/#{topic.id}", headers: auth_headers(@stranger)
      assert_response :success

      TeamMembership.find_by(team: team, user: @stranger).destroy!
      get "/api/v1/topics/#{topic.id}", headers: auth_headers(@stranger)
      assert_response :not_found

      # Including through something they had already starred.
      get "/api/v1/topics", params: { group_id: @group.id, starred_id: @stranger.id },
          headers: auth_headers(@stranger)
      assert_empty json_response["data"]
    end
  end

  test "a flagged topic stays visible to its author with the reason, and to nobody else" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)

      post "/api/v1/topics/#{topic.id}/flag", params: { reason: "off topic" },
           headers: auth_headers(@owner)
      assert_response :success

      get "/api/v1/topics/#{topic.id}", headers: auth_headers(@author)
      assert_response :success
      assert_equal "off topic", json_response["flag_reason"]
      assert json_response["flagged"]

      get "/api/v1/topics/#{topic.id}", headers: auth_headers(@stranger)
      assert_response :not_found
      get "/api/v1/topics/#{topic.id}"
      assert_response :not_found

      # A manager can still see it, or they could not undo their own decision.
      get "/api/v1/topics/#{topic.id}", headers: auth_headers(@owner)
      assert_response :success

      post "/api/v1/topics/#{topic.id}/unflag", headers: auth_headers(@owner)
      get "/api/v1/topics/#{topic.id}", headers: auth_headers(@stranger)
      assert_response :success
    end
  end

  test "a soft deleted topic is invisible to its own author too" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)

      delete "/api/v1/topics/#{topic.id}", headers: auth_headers(@author)
      assert_response :success

      get "/api/v1/topics/#{topic.id}", headers: auth_headers(@author)
      assert_response :not_found
      get "/api/v1/topics/#{topic.id}", headers: auth_headers(@owner)
      assert_response :not_found

      post "/api/v1/topics/#{topic.id}/restore", headers: auth_headers(@owner)
      assert_response :success
      get "/api/v1/topics/#{topic.id}", headers: auth_headers(@author)
      assert_response :success
    end
  end

  test "flag and delete are independent in either order" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)

      post "/api/v1/topics/#{topic.id}/flag", headers: auth_headers(@owner)
      delete "/api/v1/topics/#{topic.id}", headers: auth_headers(@owner)
      assert_response :success

      post "/api/v1/topics/#{topic.id}/restore", headers: auth_headers(@owner)
      assert_response :success
      # Restoring an undelete does not also unhide it.
      assert Topic.find(topic.id).flagged?
    end
  end

  test "a flagged reply is hidden from readers but not from its author" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)
      reply = create_reply(topic: topic, user: @stranger)

      post "/api/v1/replies/#{reply.id}/flag", params: { reason: "rude" },
           headers: auth_headers(@owner)
      assert_response :success

      get "/api/v1/topics/#{topic.id}/replies"
      assert_empty json_response["data"]

      get "/api/v1/topics/#{topic.id}/replies", headers: auth_headers(@stranger)
      assert_equal [ reply.id ], json_response["data"].map { |r| r["id"] }

      get "/api/v1/topics/#{topic.id}/replies", headers: auth_headers(@owner)
      assert_equal [ reply.id ], json_response["data"].map { |r| r["id"] }

      assert_equal 0, topic.reload.replies_count
    end
  end

  test "moving a topic to another group's board is refused" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)
      other = create_group(owner: @owner, discussion_enabled: true)
      foreign = create_category(group: other)

      patch "/api/v1/topics/#{topic.id}",
            params: { topic: { category_id: foreign.id } },
            headers: auth_headers(@owner)
      assert_response :unprocessable_entity
      assert_equal @category.id, topic.reload.category_id
    end
  end

  test "moving a topic within the group updates both boards' counts" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)
      target = create_category(group: @group)

      patch "/api/v1/topics/#{topic.id}",
            params: { topic: { category_id: target.id } },
            headers: auth_headers(@owner)
      assert_response :success
      assert_equal 0, @category.reload.topics_count
      assert_equal 1, target.reload.topics_count
    end
  end

  test "a board with topics cannot be deleted, only archived" do
    with_discussion do
      create_topic(category: @category, user: @author)

      delete "/api/v1/categories/#{@category.id}", headers: auth_headers(@owner)
      assert_response :unprocessable_entity
      assert Category.exists?(@category.id)

      patch "/api/v1/categories/#{@category.id}",
            params: { category: { archived: true } }, headers: auth_headers(@owner)
      assert_response :success

      # Archived boards drop out of the picker but their posts stay readable.
      get "/api/v1/categories", params: { group_id: @group.id }
      assert_not_includes json_response["data"].map { |c| c["id"] }, @category.id
      get "/api/v1/topics", params: { group_id: @group.id }
      assert_equal 1, json_response["data"].size
    end
  end

  test "an empty board can be deleted" do
    with_discussion do
      delete "/api/v1/categories/#{@category.id}", headers: auth_headers(@owner)
      assert_response :success
    end
  end

  test "only managers create boards, pin, flag and restore" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)

      post "/api/v1/categories", params: { category: { group_id: @group.id, name: "B" } },
           headers: auth_headers(@stranger)
      assert_response :forbidden

      post "/api/v1/topics/#{topic.id}/pin", headers: auth_headers(@author)
      assert_response :forbidden

      post "/api/v1/topics/#{topic.id}/flag", headers: auth_headers(@author)
      assert_response :forbidden

      # The author may close their own thread, though.
      post "/api/v1/topics/#{topic.id}/close", headers: auth_headers(@author)
      assert_response :success
      assert Topic.find(topic.id).closed?
    end
  end

  test "can_post_topic gates posting and a manager-only board narrows it further" do
    with_discussion do
      @group.update!(can_post_topic: "member")

      post "/api/v1/topics", params: { topic: { category_id: @category.id, title: "x" } },
           headers: auth_headers(@stranger)
      assert_response :forbidden

      create_membership(user: @stranger, group: @group)
      post "/api/v1/topics", params: { topic: { category_id: @category.id, title: "x" } },
           headers: auth_headers(@stranger)
      assert_response :created

      # "everyone" at group level does not open a manager-only board.
      @group.update!(can_post_topic: "everyone")
      board = create_category(group: @group, visibility: "manager")
      post "/api/v1/topics", params: { topic: { category_id: board.id, title: "x" } },
           headers: auth_headers(@stranger)
      assert_response :not_found
    end
  end

  test "replies are refused on a closed topic" do
    with_discussion do
      topic = create_topic(category: @category, user: @author, closed_at: Time.current)

      post "/api/v1/topics/#{topic.id}/replies", params: { reply: { content: "x" } },
           headers: auth_headers(@stranger)
      assert_response :forbidden
    end
  end

  # The test environment's cache is a null_store, so the limiter has nowhere to
  # remember anything and would silently pass. A real store is swapped in for
  # the duration — without this the test would assert nothing.
  def with_real_cache
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = previous
  end

  test "rate limiting stops a burst of posts" do
    with_discussion do
      with_real_cache do
        create_membership(user: @author, group: @group)
        post "/api/v1/topics", params: { topic: { category_id: @category.id, title: "one" } },
             headers: auth_headers(@author)
        assert_response :created

        post "/api/v1/topics", params: { topic: { category_id: @category.id, title: "two" } },
             headers: auth_headers(@author)
        assert_response :too_many_requests
      end
    end
  end

  test "a manager is not rate limited" do
    with_discussion do
      with_real_cache do
        2.times do |i|
          post "/api/v1/topics", params: { topic: { category_id: @category.id, title: "t#{i}" } },
               headers: auth_headers(@owner)
          assert_response :created
        end
      end
    end
  end

  test "starring a topic keeps stars_count in step" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)

      post "/api/v1/comments/star", params: { item_type: "Topic", item_id: topic.id },
           headers: auth_headers(@stranger)
      assert_response :success
      assert_equal 1, topic.reload.stars_count

      post "/api/v1/comments/unstar", params: { item_type: "Topic", item_id: topic.id },
           headers: auth_headers(@stranger)
      assert_response :success
      assert_equal 0, topic.reload.stars_count
    end
  end

  test "starring a reply keeps its own count and flag in step" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)
      reply = create_reply(topic: topic, user: @author)

      post "/api/v1/comments/star", params: { item_type: "Reply", item_id: reply.id },
           headers: auth_headers(@stranger)
      assert_response :success
      assert_equal 1, reply.reload.stars_count

      # The person who starred it sees is_starred; another reader does not.
      get "/api/v1/topics/#{topic.id}/replies", headers: auth_headers(@stranger)
      row = json_response["data"].find { |r| r["id"] == reply.id }
      assert row["is_starred"]
      assert_equal 1, row["stars_count"]

      get "/api/v1/topics/#{topic.id}/replies", headers: auth_headers(@owner)
      assert_not json_response["data"].find { |r| r["id"] == reply.id }["is_starred"]

      get "/api/v1/topics/#{topic.id}/replies"
      assert_not json_response["data"].find { |r| r["id"] == reply.id }["is_starred"]

      post "/api/v1/comments/unstar", params: { item_type: "Reply", item_id: reply.id },
           headers: auth_headers(@stranger)
      assert_response :success
      assert_equal 0, reply.reload.stars_count
    end
  end

  test "starring is per person, and the count is everyone's" do
    with_discussion do
      topic = create_topic(category: @category, user: @author)

      [ @author, @stranger, @owner ].each do |user|
        post "/api/v1/comments/star", params: { item_type: "Topic", item_id: topic.id },
             headers: auth_headers(user)
      end
      assert_equal 3, topic.reload.stars_count

      # Starring twice is idempotent rather than additive.
      post "/api/v1/comments/star", params: { item_type: "Topic", item_id: topic.id },
           headers: auth_headers(@author)
      assert_equal 3, topic.reload.stars_count

      get "/api/v1/topics", params: { group_id: @group.id }, headers: auth_headers(@author)
      row = json_response["data"].find { |t| t["id"] == topic.id }
      assert_equal 3, row["stars_count"]
      assert row["is_starred"]
    end
  end

  test "comment item_type is whitelisted" do
    with_discussion do
      post "/api/v1/comments/star", params: { item_type: "User", item_id: @owner.id },
           headers: auth_headers(@stranger)
      assert_response :unprocessable_entity
    end
  end

  test "discussion_enabled and can_post_topic actually persist from a group update" do
    with_discussion do
      patch "/api/v1/groups/#{@group.id}",
            params: { group: { discussion_enabled: false, can_post_topic: "manager" } },
            headers: auth_headers(@owner)
      assert_response :success

      @group.reload
      assert_equal false, @group.discussion_enabled
      assert_equal "manager", @group.can_post_topic
    end
  end
end
