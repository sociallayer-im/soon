require "test_helper"

class Api::V1::TeamsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @owner = create_user
    @manager = create_user
    @member = create_user
    @outsider = create_user
    @group = create_group(owner: @owner)
    create_membership(user: @manager, group: @group, role: "manager")
    create_membership(user: @member, group: @group)
  end

  test "a person can be in several teams at once" do
    core = create_team(group: @group)
    volunteers = create_team(group: @group)

    post "/api/v1/teams/#{core.id}/members", params: { user_id: @member.id },
         headers: auth_headers(@manager)
    assert_response :created
    post "/api/v1/teams/#{volunteers.id}/members", params: { user_id: @member.id },
         headers: auth_headers(@manager)
    assert_response :created

    assert_equal [ core.id, volunteers.id ].sort, @member.reload.teams.pluck(:id).sort
    assert_equal 1, core.reload.members_count
    assert_equal 1, volunteers.reload.members_count
  end

  test "adding the same person twice is idempotent" do
    team = create_team(group: @group)
    2.times do
      post "/api/v1/teams/#{team.id}/members", params: { user_id: @member.id },
           headers: auth_headers(@manager)
    end
    assert_equal 1, team.reload.members_count
  end

  test "someone outside the group cannot be put in one of its teams" do
    team = create_team(group: @group)

    post "/api/v1/teams/#{team.id}/members", params: { user_id: @outsider.id },
         headers: auth_headers(@manager)
    assert_response :unprocessable_entity
    assert_equal 0, team.reload.members_count
  end

  # A team groups a group's members. Someone who leaves keeps neither the
  # badge nor — through a team-restricted board — the access.
  test "leaving the group leaves its teams" do
    team = create_team(group: @group, users: [ @member ])
    other_group = create_group(owner: @owner)
    create_membership(user: @member, group: other_group)
    kept = create_team(group: other_group, users: [ @member ])

    Membership.find_by(user: @member, group: @group).destroy

    assert_equal [ kept.id ], @member.reload.teams.pluck(:id)
    assert_equal 0, team.reload.members_count
  end

  test "only managers create, edit, delete teams and change their members" do
    team = create_team(group: @group)

    post "/api/v1/teams", params: { team: { group_id: @group.id, name: "Core" } },
         headers: auth_headers(@member)
    assert_response :forbidden
    patch "/api/v1/teams/#{team.id}", params: { team: { name: "X" } },
          headers: auth_headers(@member)
    assert_response :forbidden
    delete "/api/v1/teams/#{team.id}", headers: auth_headers(@member)
    assert_response :forbidden
    post "/api/v1/teams/#{team.id}/members", params: { user_id: @member.id },
         headers: auth_headers(@member)
    assert_response :forbidden

    post "/api/v1/teams", params: { team: { group_id: @group.id, name: "Core Team" } },
         headers: auth_headers(@manager)
    assert_response :created
    assert_equal "core-team", json_response["slug"]
  end

  test "the team list is for members, not the public" do
    create_team(group: @group)

    get "/api/v1/teams", params: { group_id: @group.id }
    assert_response :unauthorized
    get "/api/v1/teams", params: { group_id: @group.id }, headers: auth_headers(@outsider)
    assert_response :forbidden
    get "/api/v1/teams", params: { group_id: @group.id }, headers: auth_headers(@member)
    assert_response :success
  end

  test "slugs are unique per group, not globally" do
    other = create_group(owner: @owner)

    post "/api/v1/teams", params: { team: { group_id: @group.id, name: "Core", slug: "core" } },
         headers: auth_headers(@owner)
    assert_response :created
    # The same slug in a different community is fine — unlike tracks, whose
    # global unique index makes the first community to use a name own it.
    post "/api/v1/teams", params: { team: { group_id: other.id, name: "Core", slug: "core" } },
         headers: auth_headers(@owner)
    assert_response :created
    # Twice in the same one is not.
    post "/api/v1/teams", params: { team: { group_id: @group.id, name: "Core", slug: "core" } },
         headers: auth_headers(@owner)
    assert_response :unprocessable_entity
  end

  # parameterize drops every non-ASCII character, so a Chinese name would
  # otherwise reduce to "" and each such team would land on team, team-2,
  # team-3 — a slug that describes nothing and collides with every sibling.
  test "a team named in Chinese still gets a distinct slug" do
    post "/api/v1/teams", params: { team: { group_id: @group.id, name: "核心团队" } },
         headers: auth_headers(@owner)
    assert_response :created
    first = json_response["slug"]

    post "/api/v1/teams", params: { team: { group_id: @group.id, name: "设计组" } },
         headers: auth_headers(@owner)
    assert_response :created
    second = json_response["slug"]

    assert_not_equal first, second
    assert_match(/\A[a-z0-9][a-z0-9-]*\z/, first)
    assert_match(/\A[a-z0-9][a-z0-9-]*\z/, second)
    # And a Latin name still reads as itself.
    post "/api/v1/teams", params: { team: { group_id: @group.id, name: "Core Team" } },
         headers: auth_headers(@owner)
    assert_equal "core-team", json_response["slug"]
  end

  test "a team can be deleted even with members, and its boards survive" do
    team = create_team(group: @group, users: [ @member ])
    board = create_category(group: @group, visibility: "team")
    CategoryTeam.create!(category: board, team: team)

    delete "/api/v1/teams/#{team.id}", headers: auth_headers(@owner)
    assert_response :success

    # The person is still in the group; only the grouping is gone.
    assert Membership.exists?(user: @member, group: @group)
    # The board is still there but now names nobody, so it is manager-only in
    # effect. That is the reason the UI warns before deleting.
    assert Category.exists?(board.id)
    assert_empty board.reload.teams
    assert_not_includes Category.visible_to(@member, group: @group).pluck(:id), board.id
    # ...but a manager still sees it, or an orphaned board would be
    # unreachable by the only people who could re-point or archive it.
    assert_includes Category.visible_to(@owner, group: @group).pluck(:id), board.id
    assert_includes Category.visible_to(@manager, group: @group).pluck(:id), board.id
  end

  test "the roster carries each member's teams without a query per member" do
    team = create_team(group: @group, users: [ @member ])
    5.times { create_membership(user: create_user, group: @group) }

    # As a member, so the private badges are actually rendered — an anonymous
    # request would skip them and the query count would prove nothing.
    few = count_queries { get "/api/v1/groups/#{@group.id}", headers: auth_headers(@member) }
    10.times { create_membership(user: create_user, group: @group) }
    many = count_queries { get "/api/v1/groups/#{@group.id}", headers: auth_headers(@member) }
    assert_equal few, many,
      "group detail went from #{few} to #{many} queries as the roster grew"

    membership = json_response["memberships"].find { |m| m["user"]["id"] == @member.id }
    assert_equal [ team.id ], membership["teams"].map { |t| t["id"] }
    assert_equal team.name, membership["teams"].first["name"]

    plain = json_response["memberships"].find { |m| m["user"]["id"] == @owner.id }
    assert_empty plain["teams"]
  end

  # The roster is a public endpoint, so a team name rides along with it. That
  # is a decision per team, not per deployment: private by default.
  test "a private team's badge reaches members only; a public one reaches anyone" do
    secret = create_team(group: @group, users: [ @member ])
    shown  = create_team(group: @group, users: [ @member ], is_public: true)

    badges = ->(headers) {
      get "/api/v1/groups/#{@group.id}", headers: headers
      json_response["memberships"].find { |m| m["user"]["id"] == @member.id }["teams"].map { |t| t["id"] }
    }

    assert_equal [ shown.id ], badges.({})
    assert_equal [ shown.id ], badges.(auth_headers(@outsider))
    assert_equal [ secret.id, shown.id ].sort, badges.(auth_headers(@member)).sort
    assert_equal [ secret.id, shown.id ].sort, badges.(auth_headers(@owner)).sort

    # The same rule on the other two endpoints that render a membership.
    get "/api/v1/groups/#{@group.id}/memberships"
    assert_equal [ shown.id ],
      json_response["data"].find { |m| m["user"]["id"] == @member.id }["teams"].map { |t| t["id"] }

    get "/api/v1/users/#{@member.id}/groups"
    assert_equal [ shown.id ], json_response.first["teams"].map { |t| t["id"] }
    get "/api/v1/users/#{@member.id}/groups", headers: auth_headers(@member)
    assert_equal [ secret.id, shown.id ].sort, json_response.first["teams"].map { |t| t["id"] }.sort
  end

  test "a platform admin sees private badges the way they see everything else" do
    secret = create_team(group: @group, users: [ @member ])
    admin = create_user
    admin.update!(admin: true)

    get "/api/v1/groups/#{@group.id}", headers: auth_headers(admin)
    badges = json_response["memberships"].find { |m| m["user"]["id"] == @member.id }["teams"]
    assert_equal [ secret.id ], badges.map { |t| t["id"] }
  end

  # Every group-detail renderer has to pass the viewer, not just #show —
  # otherwise a manager who edits the group gets a response with the private
  # badges stripped out and the roster appears to lose them.
  test "the group update response still carries the viewer's badges" do
    secret = create_team(group: @group, users: [ @member ])

    patch "/api/v1/groups/#{@group.id}", params: { group: { bio: "hi" } },
          headers: auth_headers(@owner)
    assert_response :success
    badges = json_response["memberships"].find { |m| m["user"]["id"] == @member.id }["teams"]
    assert_equal [ secret.id ], badges.map { |t| t["id"] }
  end

  test "a signed-in group detail response is never cached" do
    get "/api/v1/groups/#{@group.id}"
    assert_match(/max-age=30/, response.headers["Cache-Control"].to_s)

    # It personalizes now, so a response carrying private badges must not be
    # stored anywhere shared.
    get "/api/v1/groups/#{@group.id}", headers: auth_headers(@member)
    assert_no_match(/max-age=30/, response.headers["Cache-Control"].to_s)
  end

  test "a team-restricted board is visible to its team and to nobody else" do
    ENV["DISCUSSION_ENABLED"] = "true"
    @group.update!(discussion_enabled: true)
    team = create_team(group: @group, users: [ @member ])
    board = create_category(group: @group, visibility: "team")
    CategoryTeam.create!(category: board, team: team)
    topic = create_topic(category: board, user: @member)

    get "/api/v1/topics/#{topic.id}", headers: auth_headers(@member)
    assert_response :success

    plain_member = create_user
    create_membership(user: plain_member, group: @group)
    get "/api/v1/topics/#{topic.id}", headers: auth_headers(plain_member)
    assert_response :not_found

    get "/api/v1/topics/#{topic.id}", headers: auth_headers(@outsider)
    assert_response :not_found
    get "/api/v1/topics/#{topic.id}"
    assert_response :not_found
  ensure
    ENV.delete("DISCUSSION_ENABLED")
  end

  test "a board can only name teams from its own group" do
    ENV["DISCUSSION_ENABLED"] = "true"
    @group.update!(discussion_enabled: true)
    board = create_category(group: @group, visibility: "team")
    foreign = create_team(group: create_group(owner: @owner))

    patch "/api/v1/categories/#{board.id}",
          params: { category: { team_ids: [ foreign.id ] } }, headers: auth_headers(@owner)
    assert_response :success
    assert_empty board.reload.teams
  ensure
    ENV.delete("DISCUSSION_ENABLED")
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
end
