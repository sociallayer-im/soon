require "test_helper"

# The two gates, the submit tiers, project visibility, the one-project rule,
# the submission window, jsonb tracks and the judge role's non-power.
class Api::V1::HackathonsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @owner    = create_user
    @member   = create_user
    @member2  = create_user
    @stranger = create_user
    @group = create_group(owner: @owner, hackathon_enabled: true)
    create_membership(user: @member, group: @group)
    create_membership(user: @member2, group: @group)
    @event = create_event(group: @group, owner: @owner)
  end

  def with_hackathons(&block)
    ENV["HACKATHON_ENABLED"] = "true"
    yield
  ensure
    ENV.delete("HACKATHON_ENABLED")
  end

  def body = JSON.parse(response.body)

  test "every endpoint 404s when the deployment gate is closed" do
    h = create_hackathon(group: @group, user: @owner)
    ENV.delete("HACKATHON_ENABLED")
    get "/api/v1/hackathons", params: { group_id: @group.id }
    assert_response :not_found
    get "/api/v1/hackathons/#{h.id}"
    assert_response :not_found
    get "/api/v1/hackathon_projects", params: { hackathon_id: h.id }
    assert_response :not_found
  end

  test "turning a group's hackathons off closes every endpoint, by the record's own group" do
    with_hackathons do
      h = create_hackathon(group: @group, user: @owner)
      p = create_hackathon_project(hackathon: h, user: @member)
      @group.update!(hackathon_enabled: false)

      get "/api/v1/hackathons/#{h.id}"
      assert_response :not_found
      get "/api/v1/hackathon_projects/#{p.id}"
      assert_response :not_found
      post "/api/v1/hackathon_projects/#{p.id}/submit", headers: auth_headers(@member)
      assert_response :not_found
      get "/api/v1/hackathons/#{h.id}/export", headers: auth_headers(@owner)
      assert_response :not_found
    end
  end

  test "creation follows can_create_hackathon, default manager" do
    with_hackathons do
      params = { hackathon: { group_id: @group.id, title: "h", can_submit_project: "member", projects_visibility: "always" } }
      post "/api/v1/hackathons", params: params, headers: auth_headers(@member)
      assert_response :forbidden
      post "/api/v1/hackathons", params: params, headers: auth_headers(@owner)
      assert_response :created
      assert_equal "draft", body["status"]

      @group.update!(can_create_hackathon: "member")
      post "/api/v1/hackathons", params: params, headers: auth_headers(@member)
      assert_response :created
      post "/api/v1/hackathons", params: params, headers: auth_headers(@stranger)
      assert_response :forbidden
    end
  end

  test "drafts are visible only to the organiser; index respects that" do
    with_hackathons do
      h = create_hackathon(group: @group, user: @owner, status: "draft")
      get "/api/v1/hackathons/#{h.id}"
      assert_response :not_found
      get "/api/v1/hackathons/#{h.id}", headers: auth_headers(@member)
      assert_response :not_found
      get "/api/v1/hackathons/#{h.id}", headers: auth_headers(@owner)
      assert_response :ok
      assert body["can_manage"]

      get "/api/v1/hackathons", params: { group_id: @group.id }
      assert_equal 0, body["data"].size
      get "/api/v1/hackathons", params: { group_id: @group.id }, headers: auth_headers(@owner)
      assert_equal 1, body["data"].size
    end
  end

  test "the participant tier needs an event and reads its attending list" do
    with_hackathons do
      post "/api/v1/hackathons", params: { hackathon: { group_id: @group.id, title: "h", can_submit_project: "participant" } },
           headers: auth_headers(@owner)
      assert_response :unprocessable_entity
      assert_match(/registration event/, body["error"])

      h = create_hackathon(group: @group, user: @owner, event: @event)
      create_participant(event: @event, user: @member)
      create_participant(event: @event, user: @member2, status: "pending")

      get "/api/v1/hackathons/#{h.id}", headers: auth_headers(@member)
      assert body["can_submit"]
      get "/api/v1/hackathons/#{h.id}", headers: auth_headers(@member2)
      assert_not body["can_submit"]

      proj = { hackathon_project: { hackathon_id: h.id, title: "p" } }
      post "/api/v1/hackathon_projects", params: proj, headers: auth_headers(@member)
      assert_response :created
      assert_equal "owner", body["members"][0]["role"]
      post "/api/v1/hackathon_projects", params: proj, headers: auth_headers(@member2)
      assert_response :forbidden
    end
  end

  test "an event must belong to the group, and deleting it nulls the link" do
    with_hackathons do
      other = create_group(owner: @stranger)
      foreign = create_event(group: other, owner: @stranger)
      assert_raises(ActiveRecord::RecordInvalid) { create_hackathon(group: @group, user: @owner, event: foreign) }

      h = create_hackathon(group: @group, user: @owner, event: @event)
      @event.destroy!
      assert_nil h.reload.event_id
      get "/api/v1/hackathons/#{h.id}", headers: auth_headers(@member)
      assert_not body["can_submit"]
      assert body["event_missing"]
    end
  end

  test "one person, one project per hackathon" do
    with_hackathons do
      h = create_hackathon(group: @group, user: @owner)
      p1 = create_hackathon_project(hackathon: h, user: @member, recruiting: true)
      p2 = create_hackathon_project(hackathon: h, user: @member2, recruiting: true)

      # Only the owner adds people; there is no self-join.
      post "/api/v1/hackathon_projects/#{p2.id}/members", params: { user_id: @member.id }, headers: auth_headers(@member2)
      assert_response :unprocessable_entity
      assert_match(/already on a project/, body["error"])

      delete "/api/v1/hackathon_projects/#{p1.id}/join", headers: auth_headers(@member)
      assert_response :forbidden   # owners cannot leave
      p1.destroy!
      post "/api/v1/hackathon_projects/#{p2.id}/members", params: { user_id: @member.id }, headers: auth_headers(@member2)
      assert_response :ok
      assert_equal 2, body["members_count"]
      # Members can leave on their own; the owner cannot.
      delete "/api/v1/hackathon_projects/#{p2.id}/join", headers: auth_headers(@member)
      assert_response :ok
      assert_equal 1, body["members_count"]

      # A second hackathon is a separate slot.
      h2 = create_hackathon(group: @group, user: @owner)
      post "/api/v1/hackathon_projects", params: { hackathon_project: { hackathon_id: h2.id, title: "x" } },
           headers: auth_headers(@member)
      assert_response :created
    end
  end

  test "the submission window is enforced server-side and locks the project" do
    with_hackathons do
      h = create_hackathon(group: @group, user: @owner, submit_open_at: 1.day.from_now)
      p = create_hackathon_project(hackathon: h, user: @member)
      post "/api/v1/hackathon_projects/#{p.id}/submit", headers: auth_headers(@member)
      assert_response :unprocessable_entity
      assert_match(/not open/, body["error"])

      h.update!(submit_open_at: nil)
      create_membership(user: @stranger, group: @group)
      p.hackathon_project_members.create!(user: @stranger)
      post "/api/v1/hackathon_projects/#{p.id}/submit", headers: auth_headers(@stranger)
      assert_response :unprocessable_entity
      assert_match(/only the owner/, body["error"])

      post "/api/v1/hackathon_projects/#{p.id}/submit", headers: auth_headers(@member)
      assert_response :ok
      assert_equal "submitted", body["status"]
      assert_equal 1, h.reload.projects_count

      # Members lose edit after submission; the owner keeps it.
      patch "/api/v1/hackathon_projects/#{p.id}", params: { hackathon_project: { title: "t2" } }, headers: auth_headers(@stranger)
      assert_response :forbidden
      patch "/api/v1/hackathon_projects/#{p.id}", params: { hackathon_project: { title: "t2" } }, headers: auth_headers(@member)
      assert_response :ok

      # Withdraw before close; not after.
      delete "/api/v1/hackathon_projects/#{p.id}/submit", headers: auth_headers(@member)
      assert_response :ok
      assert_equal "draft", body["status"]
      assert_equal 0, h.reload.projects_count
      post "/api/v1/hackathon_projects/#{p.id}/submit", headers: auth_headers(@member)
      h.update!(submit_close_at: 1.minute.ago)
      delete "/api/v1/hackathon_projects/#{p.id}/submit", headers: auth_headers(@member)
      assert_response :forbidden
      delete "/api/v1/hackathon_projects/#{p.id}", headers: auth_headers(@member)
      assert_response :forbidden
    end
  end

  test "projects_visibility gates outsiders but never members or organisers" do
    with_hackathons do
      h = create_hackathon(group: @group, user: @owner, projects_visibility: "after_submit", submit_close_at: 1.day.from_now)
      p = create_hackathon_project(hackathon: h, user: @member)
      p.submit!

      get "/api/v1/hackathon_projects/#{p.id}"
      assert_response :not_found
      get "/api/v1/hackathon_projects", params: { hackathon_id: h.id }, headers: auth_headers(@member2)
      assert_equal 0, body["data"].size
      get "/api/v1/hackathon_projects", params: { hackathon_id: h.id }, headers: auth_headers(@member)
      assert_equal 1, body["data"].size
      get "/api/v1/hackathon_projects/#{p.id}", headers: auth_headers(@owner)
      assert_response :ok

      h.update!(submit_close_at: 1.minute.ago)
      get "/api/v1/hackathon_projects/#{p.id}"
      assert_response :ok
      assert_nil body["review_note"]

      h.update!(projects_visibility: "after_review")
      get "/api/v1/hackathon_projects/#{p.id}"
      assert_response :not_found
      post "/api/v1/hackathon_projects/#{p.id}/review", params: { decision: "reject", note: "no" }, headers: auth_headers(@member)
      assert_response :forbidden
      post "/api/v1/hackathon_projects/#{p.id}/review", params: { decision: "approve" }, headers: auth_headers(@owner)
      assert_response :ok
      assert_equal "approved", body["status"]
      get "/api/v1/hackathon_projects/#{p.id}"
      assert_response :ok

      # Drafts never leak, but a recruiting draft is findable with ?recruiting=true.
      d = create_hackathon_project(hackathon: h, user: @member2, recruiting: true)
      get "/api/v1/hackathon_projects/#{d.id}"
      assert_response :not_found
      get "/api/v1/hackathon_projects", params: { hackathon_id: h.id, recruiting: true }
      assert_equal [ d.id ], body["data"].map { |x| x["id"] }
    end
  end

  test "tracks are minted server-side and cannot be removed while in use" do
    with_hackathons do
      h = create_hackathon(group: @group, user: @owner)
      patch "/api/v1/hackathons/#{h.id}/tracks", params: { tracks: [ { title: "AI" }, { title: "Public goods", id: "forged" } ] },
            headers: auth_headers(@owner)
      assert_response :ok
      ids = body["tracks"].map { |t| t["id"] }
      assert_equal 2, ids.uniq.size
      assert_not_includes ids, "forged"

      ai = ids[0]
      post "/api/v1/hackathon_projects", params: { hackathon_project: { hackathon_id: h.id, title: "p", track_id: "nope" } },
           headers: auth_headers(@member)
      assert_response :unprocessable_entity
      post "/api/v1/hackathon_projects", params: { hackathon_project: { hackathon_id: h.id, title: "p", track_id: ai } },
           headers: auth_headers(@member)
      assert_response :created

      patch "/api/v1/hackathons/#{h.id}/tracks", params: { tracks: [ { id: ids[1], title: "Public goods" } ] },
            headers: auth_headers(@owner)
      assert_response :unprocessable_entity
      assert_match(/still use/, body["error"])

      # Renaming keeps the id.
      patch "/api/v1/hackathons/#{h.id}/tracks", params: { tracks: [ { id: ai, title: "AI apps" }, { id: ids[1], title: "PG" } ] },
            headers: auth_headers(@owner)
      assert_equal ai, body["tracks"][0]["id"]
      assert_equal "AI apps", body["tracks"][0]["title"]
      get "/api/v1/hackathon_projects", params: { hackathon_id: h.id, track_id: ai }, headers: auth_headers(@owner)
      assert_equal 1, body["data"].size
    end
  end

  test "stars, transfer and member management" do
    with_hackathons do
      h = create_hackathon(group: @group, user: @owner)
      p = create_hackathon_project(hackathon: h, user: @member)
      p.submit!

      post "/api/v1/hackathon_projects/#{p.id}/star", headers: auth_headers(@member2)
      assert_equal 1, body["stars_count"]
      assert body["starred_by_me"]
      post "/api/v1/hackathon_projects/#{p.id}/star", headers: auth_headers(@member2)
      assert_equal 1, body["stars_count"]
      delete "/api/v1/hackathon_projects/#{p.id}/star", headers: auth_headers(@member2)
      assert_equal 0, body["stars_count"]

      post "/api/v1/hackathon_projects/#{p.id}/members", params: { user_id: @stranger.id }, headers: auth_headers(@member)
      assert_response :unprocessable_entity   # not a group member → not eligible
      post "/api/v1/hackathon_projects/#{p.id}/members", params: { user_id: @member2.id }, headers: auth_headers(@member2)
      assert_response :forbidden
      post "/api/v1/hackathon_projects/#{p.id}/members", params: { user_id: @member2.id }, headers: auth_headers(@member)
      assert_response :unprocessable_entity   # locked after submission
      p.unsubmit!
      post "/api/v1/hackathon_projects/#{p.id}/members", params: { user_id: @member2.id }, headers: auth_headers(@member)
      assert_response :ok
      assert_equal 2, body["members_count"]

      delete "/api/v1/hackathon_projects/#{p.id}/members/#{@member.id}", headers: auth_headers(@member)
      assert_response :unprocessable_entity
      post "/api/v1/hackathon_projects/#{p.id}/transfer", params: { user_id: @member2.id }, headers: auth_headers(@member)
      assert_response :ok
      assert_equal @member2.id, body["user"]["id"]
      assert_equal "owner", body["members"].find { |m| m["id"] == @member2.id }["role"]
      delete "/api/v1/hackathon_projects/#{p.id}/members/#{@member.id}", headers: auth_headers(@member2)
      assert_response :ok
      assert_equal 1, body["members_count"]
    end
  end

  test "a judge is listed on the event but cannot edit it; judges_team snapshots them" do
    with_hackathons do
      judge = create_user
      create_membership(user: judge, group: @group)
      create_event_role(event: @event, item: judge, role: "judge")
      create_event_role(event: @event, item: nil, item_type: "User", role: "judge", email: "x@example.com", display_name: "Ext")
      speaker = create_user
      create_event_role(event: @event, item: speaker, role: "speaker")

      assert_not EventPolicy.new(judge, @event).update?
      assert EventPolicy.new(speaker, @event).update?

      h = create_hackathon(group: @group, user: @owner, event: @event)
      post "/api/v1/hackathons/#{h.id}/judges_team", headers: auth_headers(@owner)
      assert_response :ok
      assert_equal 1, body["added"]
      assert_equal [ "Ext" ], body["skipped"]
      team = Team.find(body["team"]["id"])
      assert_equal [ judge.id ], team.users.pluck(:id)

      # Re-run diffs: judge removed → membership removed.
      @event.event_roles.where(item_id: judge.id).destroy_all
      post "/api/v1/hackathons/#{h.id}/judges_team", headers: auth_headers(@owner)
      assert_equal 1, body["removed"]
      assert_equal 0, team.reload.members_count
    end
  end

  test "export is organiser-only CSV" do
    with_hackathons do
      h = create_hackathon(group: @group, user: @owner)
      p = create_hackathon_project(hackathon: h, user: @member, award: "Best")
      p.submit!
      get "/api/v1/hackathons/#{h.id}/export", headers: auth_headers(@member)
      assert_response :forbidden
      get "/api/v1/hackathons/#{h.id}/export", headers: auth_headers(@owner)
      assert_response :ok
      rows = CSV.parse(response.body)
      assert_equal "title", rows[0][0]
      assert_equal [ p.title, "Best" ], [ rows[1][0], rows[1][3] ]
    end
  end

  test "flagging a project hides it and drops it from the count; organiser and members still see it" do
    with_hackathons do
      h = create_hackathon(group: @group, user: @owner)
      p = create_hackathon_project(hackathon: h, user: @member)
      p.submit!
      post "/api/v1/hackathon_projects/#{p.id}/flag", params: { reason: "spam" }, headers: auth_headers(@owner)
      assert_response :ok
      get "/api/v1/hackathon_projects/#{p.id}"
      assert_response :not_found
      get "/api/v1/hackathon_projects/#{p.id}", headers: auth_headers(@member)
      assert_response :ok
      assert_equal "spam", body["flag_reason"]
      get "/api/v1/hackathon_projects", params: { hackathon_id: h.id }
      assert_equal 0, body["data"].size
    end
  end
end
