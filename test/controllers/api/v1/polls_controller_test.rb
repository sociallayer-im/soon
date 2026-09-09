require "test_helper"

# The two gates, the three poll types, and every read path through which a
# poll's visibility setting could leak who chose what.
class Api::V1::PollsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @owner    = create_user
    @member   = create_user
    @member2  = create_user
    @stranger = create_user
    @group = create_group(owner: @owner, poll_enabled: true)
    create_membership(user: @member, group: @group)
    create_membership(user: @member2, group: @group)
  end

  def with_polls(&block)
    ENV["POLL_ENABLED"] = "true"
    yield
  ensure
    ENV.delete("POLL_ENABLED")
  end

  def option_id(poll, title)
    poll.poll_options.find_by!(title: title).id
  end

  test "every poll endpoint 404s when the deployment gate is closed" do
    poll = create_poll(group: @group, user: @member)
    ENV.delete("POLL_ENABLED")
    get "/api/v1/polls", params: { group_id: @group.id }
    assert_response :not_found
    get "/api/v1/polls/#{poll.id}"
    assert_response :not_found
    post "/api/v1/polls", params: { poll: { group_id: @group.id, title: "x", options: [ { title: "a" }, { title: "b" } ] } },
         headers: auth_headers(@member)
    assert_response :not_found
  end

  test "turning a group's polls off closes every endpoint, not just the list" do
    with_polls do
      poll = create_poll(group: @group, user: @member)
      @group.update!(poll_enabled: false)

      get "/api/v1/polls", params: { group_id: @group.id }
      assert_response :not_found
      get "/api/v1/polls/#{poll.id}"
      assert_response :not_found
      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: option_id(poll, "A") },
           headers: auth_headers(@member)
      assert_response :not_found
      patch "/api/v1/polls/#{poll.id}", params: { poll: { title: "changed" } }, headers: auth_headers(@member)
      assert_response :not_found
      get "/api/v1/polls/#{poll.id}/export", headers: auth_headers(@owner)
      assert_response :not_found
    end
  end

  test "reads are public; creation follows can_create_poll" do
    with_polls do
      poll = create_poll(group: @group, user: @member)
      get "/api/v1/polls", params: { group_id: @group.id }
      assert_response :success
      assert_equal [ poll.id ], json_response["data"].map { |p| p["id"] }
      get "/api/v1/polls/#{poll.id}"
      assert_response :success
      assert_nil json_response["my_vote"]

      body = { poll: { group_id: @group.id, title: "Lunch?", options: [ { title: "Pizza" }, { title: "Sushi" } ] } }
      post "/api/v1/polls", params: body, headers: auth_headers(@stranger)
      assert_response :forbidden
      post "/api/v1/polls", params: body, headers: auth_headers(@member)
      assert_response :created
      assert_equal %w[Pizza Sushi], json_response["options"].map { |o| o["title"] }
      assert_equal "single", json_response["poll_type"]

      @group.update!(can_create_poll: "manager")
      post "/api/v1/polls", params: body, headers: auth_headers(@member)
      assert_response :forbidden
      post "/api/v1/polls", params: body, headers: auth_headers(@owner)
      assert_response :created

      @group.update!(can_create_poll: "everyone")
      post "/api/v1/polls", params: body, headers: auth_headers(@stranger)
      assert_response :created
    end
  end

  test "a poll needs at least two options" do
    with_polls do
      post "/api/v1/polls", params: { poll: { group_id: @group.id, title: "x", options: [ { title: "only" } ] } },
           headers: auth_headers(@member)
      assert_response :unprocessable_entity
      assert_equal 0, Poll.count
    end
  end

  test "single choice: voting, changing, retracting keep counts in step" do
    with_polls do
      poll = create_poll(group: @group, user: @owner)
      a, b = option_id(poll, "A"), option_id(poll, "B")

      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: a }, headers: auth_headers(@stranger)
      assert_response :forbidden

      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: a }, headers: auth_headers(@member)
      assert_response :success
      assert_equal a, json_response["my_vote"]
      assert_equal 1, json_response["votes_count"]

      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: b }, headers: auth_headers(@member)
      assert_response :success
      assert_equal b, json_response["my_vote"]
      counts = json_response["options"].to_h { |o| [ o["title"], o["votes_count"] ] }
      assert_equal({ "A" => 0, "B" => 1 }, counts)
      assert_equal 1, poll.poll_votes.count

      delete "/api/v1/polls/#{poll.id}/vote", headers: auth_headers(@member)
      assert_response :success
      assert_nil json_response["my_vote"]
      assert_equal 0, json_response["votes_count"]

      other = create_poll(group: @group, user: @owner)
      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: option_id(other, "A") }, headers: auth_headers(@member)
      assert_response :unprocessable_entity
    end
  end

  test "multiple choice: option_ids is the full set, votes_count counts people" do
    with_polls do
      poll = create_poll(group: @group, user: @owner, poll_type: "multiple", options: %w[A B C])
      a, b, c = %w[A B C].map { |t| option_id(poll, t) }

      post "/api/v1/polls/#{poll.id}/vote", params: { option_ids: [ a, b ] }, headers: auth_headers(@member)
      assert_response :success
      assert_equal [ a, b ].sort, json_response["my_vote"].sort
      assert_equal 1, json_response["votes_count"]

      post "/api/v1/polls/#{poll.id}/vote", params: { option_ids: [ b, c ] }, headers: auth_headers(@member)
      assert_response :success
      assert_equal [ b, c ].sort, json_response["my_vote"].sort
      counts = json_response["options"].to_h { |o| [ o["title"], o["votes_count"] ] }
      assert_equal({ "A" => 0, "B" => 1, "C" => 1 }, counts)
      assert_equal 1, json_response["votes_count"]
    end
  end

  test "number: value is range-checked and stats aggregate" do
    with_polls do
      poll = create_poll(group: @group, user: @owner, poll_type: "number", min_value: 1, max_value: 5)
      assert_equal 0, poll.poll_options.count

      post "/api/v1/polls/#{poll.id}/vote", params: { value: 9 }, headers: auth_headers(@member)
      assert_response :unprocessable_entity
      post "/api/v1/polls/#{poll.id}/vote", params: { value: 4 }, headers: auth_headers(@member)
      assert_response :success
      assert_equal 4, json_response["my_vote"]
      post "/api/v1/polls/#{poll.id}/vote", params: { value: 2 }, headers: auth_headers(@member2)
      assert_response :success
      assert_equal 3.0, json_response["stats"]["average"]
      assert_equal 3.0, json_response["stats"]["median"]
      assert_equal({ "2" => 1, "4" => 1 }, json_response["stats"]["histogram"])
    end
  end

  test "a number poll needs a valid range" do
    with_polls do
      post "/api/v1/polls", params: { poll: { group_id: @group.id, title: "x", poll_type: "number", min_value: 5, max_value: 1 } },
           headers: auth_headers(@member)
      assert_response :unprocessable_entity
    end
  end

  test "visibility: participants hides choices, secret hides the roster, managers see all" do
    with_polls do
      poll = create_poll(group: @group, user: @member, visibility: "participants")
      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: option_id(poll, "A") }, headers: auth_headers(@member2)

      get "/api/v1/polls/#{poll.id}", headers: auth_headers(@member)
      assert_equal [ @member2.id ], json_response["voters"].map { |v| v["id"] }
      refute json_response["voters"].first.key?("choice")
      assert_equal 1, json_response["options"].find { |o| o["title"] == "A" }["votes_count"]

      poll.update!(visibility: "secret")
      get "/api/v1/polls/#{poll.id}", headers: auth_headers(@member)
      assert_nil json_response["voters"]
      get "/api/v1/polls/#{poll.id}"
      assert_nil json_response["voters"]

      get "/api/v1/polls/#{poll.id}", headers: auth_headers(@owner)
      assert_equal option_id(poll, "A"), json_response["voters"].first["choice"]

      poll.update!(visibility: "public")
      get "/api/v1/polls/#{poll.id}", headers: auth_headers(@stranger)
      assert_equal option_id(poll, "A"), json_response["voters"].first["choice"]
    end
  end

  test "results: on_close and manager_only withhold counts, my_vote stays" do
    with_polls do
      poll = create_poll(group: @group, user: @owner, results: "on_close")
      a = option_id(poll, "A")
      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: a }, headers: auth_headers(@member)
      assert_equal a, json_response["my_vote"]
      assert_nil json_response["options"].first["votes_count"]
      assert_equal false, json_response["can_see_results"]
      assert_nil json_response["voters"]

      post "/api/v1/polls/#{poll.id}/close", headers: auth_headers(@owner)
      get "/api/v1/polls/#{poll.id}", headers: auth_headers(@member)
      assert_equal 1, json_response["options"].first["votes_count"]
      assert_equal true, json_response["closed"]

      mo = create_poll(group: @group, user: @owner, results: "manager_only")
      post "/api/v1/polls/#{mo.id}/vote", params: { option_id: option_id(mo, "A") }, headers: auth_headers(@member)
      assert_nil json_response["options"].first["votes_count"]
      get "/api/v1/polls/#{mo.id}", headers: auth_headers(@owner)
      assert_equal 1, json_response["options"].first["votes_count"]
    end
  end

  test "results: on_vote opens after voting" do
    with_polls do
      poll = create_poll(group: @group, user: @owner, results: "on_vote")
      get "/api/v1/polls/#{poll.id}", headers: auth_headers(@member)
      assert_equal false, json_response["can_see_results"]
      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: option_id(poll, "A") }, headers: auth_headers(@member)
      assert_equal true, json_response["can_see_results"]
    end
  end

  test "a closed poll takes no votes; a deadline in the past counts as closed" do
    with_polls do
      poll = create_poll(group: @group, user: @owner, close_at: 1.minute.ago)
      get "/api/v1/polls/#{poll.id}"
      assert_equal true, json_response["closed"]
      assert_equal false, json_response["can_vote"]
      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: option_id(poll, "A") }, headers: auth_headers(@member)
      assert_response :forbidden

      get "/api/v1/polls", params: { group_id: @group.id, status: "open" }
      assert_equal [], json_response["data"]
      get "/api/v1/polls", params: { group_id: @group.id, status: "closed" }
      assert_equal [ poll.id ], json_response["data"].map { |p| p["id"] }
    end
  end

  test "editing: options lock after the grace window, visibility locks at the first vote" do
    with_polls do
      poll = create_poll(group: @group, user: @member)
      a = option_id(poll, "A")
      patch "/api/v1/polls/#{poll.id}", params: { poll: { options: [ { id: a, title: "A2" }, { title: "C" } ] } },
            headers: auth_headers(@member)
      assert_response :success
      assert_equal %w[A2 C], json_response["options"].map { |o| o["title"] }
      assert_equal 2, poll.poll_options.count

      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: a }, headers: auth_headers(@member2)
      patch "/api/v1/polls/#{poll.id}", params: { poll: { title: "still fine" } }, headers: auth_headers(@member)
      assert_response :success
      patch "/api/v1/polls/#{poll.id}", params: { poll: { visibility: "secret" } }, headers: auth_headers(@member)
      assert_response :unprocessable_entity

      poll.update_columns(first_voted_at: 11.minutes.ago)
      patch "/api/v1/polls/#{poll.id}", params: { poll: { title: "too late" } }, headers: auth_headers(@member)
      assert_response :unprocessable_entity
      patch "/api/v1/polls/#{poll.id}", params: { poll: { content: "clarified", close_at: 1.day.from_now } },
            headers: auth_headers(@member)
      assert_response :success
      assert_equal false, json_response["editable"]

      patch "/api/v1/polls/#{poll.id}", params: { poll: { content: "x" } }, headers: auth_headers(@member2)
      assert_response :forbidden
    end
  end

  test "flag hides a poll from everyone but its author and managers; delete hides it from all" do
    with_polls do
      poll = create_poll(group: @group, user: @member)
      post "/api/v1/polls/#{poll.id}/flag", params: { reason: "spam" }, headers: auth_headers(@member)
      assert_response :forbidden
      post "/api/v1/polls/#{poll.id}/flag", params: { reason: "spam" }, headers: auth_headers(@owner)
      assert_response :success

      get "/api/v1/polls/#{poll.id}", headers: auth_headers(@member2)
      assert_response :not_found
      get "/api/v1/polls/#{poll.id}", headers: auth_headers(@member)
      assert_equal "spam", json_response["flag_reason"]
      get "/api/v1/polls", params: { group_id: @group.id }, headers: auth_headers(@member2)
      assert_equal [], json_response["data"]
      get "/api/v1/polls", params: { group_id: @group.id }, headers: auth_headers(@owner)
      assert_equal 1, json_response["data"].size

      delete "/api/v1/polls/#{poll.id}", headers: auth_headers(@member)
      assert_response :success
      get "/api/v1/polls/#{poll.id}", headers: auth_headers(@member)
      assert_response :not_found
      post "/api/v1/polls/#{poll.id}/restore", headers: auth_headers(@owner)
      assert_response :success
      get "/api/v1/polls/#{poll.id}", headers: auth_headers(@member)
      assert_response :success
    end
  end

  test "csv export: by=option always, by=voter only where choices are visible" do
    with_polls do
      poll = create_poll(group: @group, user: @member, visibility: "participants")
      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: option_id(poll, "A") }, headers: auth_headers(@member2)

      get "/api/v1/polls/#{poll.id}/export", headers: auth_headers(@member2)
      assert_response :forbidden

      get "/api/v1/polls/#{poll.id}/export", params: { by: "option" }, headers: auth_headers(@member)
      assert_response :success
      assert_equal "option,votes,percentage\nA,1,100.0\nB,0,0.0\n", response.body

      get "/api/v1/polls/#{poll.id}/export", params: { by: "voter" }, headers: auth_headers(@member)
      assert_response :forbidden

      get "/api/v1/polls/#{poll.id}/export", params: { by: "voter" }, headers: auth_headers(@owner)
      assert_response :success
      assert_includes response.body, "#{@member2.id},#{@member2.name},A,"

      poll.update!(visibility: "public")
      get "/api/v1/polls/#{poll.id}/export", params: { by: "voter" }, headers: auth_headers(@member)
      assert_response :success
    end
  end

  test "eligibility: a team or another group replaces the members-only default; managers always may" do
    with_polls do
      team = @group.teams.create!(name: "Volunteers", slug: "volunteers")
      TeamMembership.create!(team: team, user: @member)
      other_group = create_group(owner: @stranger)
      outsider = create_user
      create_membership(user: outsider, group: other_group)

      post "/api/v1/polls", params: { poll: { group_id: @group.id, title: "x", options: [ { title: "a" }, { title: "b" } ],
                                              eligible_team_ids: [ team.id ] } },
           headers: auth_headers(@owner)
      assert_response :created
      poll = Poll.find(json_response["id"])
      assert_equal [ "Volunteers" ], json_response["eligible_teams"].map { |t| t["name"] }
      a = poll.poll_options.first.id

      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: a }, headers: auth_headers(@member)
      assert_response :success
      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: a }, headers: auth_headers(@member2)
      assert_response :forbidden, "a member outside the team is no longer eligible"
      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: a }, headers: auth_headers(@owner)
      assert_response :success, "managers always may"

      poll.update!(eligible_team_ids: [], eligible_group_ids: [ other_group.id ])
      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: a }, headers: auth_headers(outsider)
      assert_response :success
      post "/api/v1/polls/#{poll.id}/vote", params: { option_id: a }, headers: auth_headers(@member2)
      assert_response :forbidden

      # Only this group's teams; unknown groups are refused too.
      foreign_team = other_group.teams.create!(name: "T", slug: "t")
      post "/api/v1/polls", params: { poll: { group_id: @group.id, title: "x", options: [ { title: "a" }, { title: "b" } ],
                                              eligible_team_ids: [ foreign_team.id ] } },
           headers: auth_headers(@owner)
      assert_response :unprocessable_entity
      post "/api/v1/polls", params: { poll: { group_id: @group.id, title: "x", options: [ { title: "a" }, { title: "b" } ],
                                              eligible_group_ids: [ "nope" ] } },
           headers: auth_headers(@owner)
      assert_response :unprocessable_entity

      # Eligibility is locked with the options once the grace window passes.
      poll.update_columns(first_voted_at: 11.minutes.ago)
      patch "/api/v1/polls/#{poll.id}", params: { poll: { eligible_group_ids: [] } }, headers: auth_headers(@owner)
      assert_response :unprocessable_entity
    end
  end

  test "poll_enabled and can_create_poll persist from a group update" do
    patch "/api/v1/groups/#{@group.id}",
          params: { group: { poll_enabled: false, can_create_poll: "manager" } },
          headers: auth_headers(@owner)
    assert_response :success
    @group.reload
    assert_equal false, @group.poll_enabled
    assert_equal "manager", @group.can_create_poll
    get "/api/v1/groups/#{@group.id}", headers: auth_headers(@owner)
    assert_equal "manager", json_response["can_create_poll"]
  end
end
