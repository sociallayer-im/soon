require "test_helper"

class Api::V1::GroupInvitesControllerTest < ActionDispatch::IntegrationTest
  test "create directly adds a known user by handle, no invite row" do
    owner = create_user
    target = create_user
    group = create_group(owner: owner)

    assert_no_difference "GroupInvite.count" do
      post "/api/v1/groups/#{group.id}/group_invites",
        params: { receivers: [target.name], role: "member" }, headers: auth_headers(owner)
    end
    assert_response :success
    assert_equal "added", json_response["results"].first["result"]
    assert group.memberships.exists?(user: target, role: "member")
  end

  test "create upgrades an existing member's role without creating an invite" do
    owner = create_user
    target = create_user
    group = create_group(owner: owner)
    create_membership(user: target, group: group, role: "member")

    assert_no_difference "GroupInvite.count" do
      post "/api/v1/groups/#{group.id}/group_invites",
        params: { receivers: [target.name], role: "manager" }, headers: auth_headers(owner)
    end
    assert_equal "role_updated", json_response["results"].first["result"]
    assert_equal "manager", group.memberships.find_by(user: target).role
  end

  test "create errors when the known user is already a member at an equal/higher role" do
    owner = create_user
    target = create_user
    group = create_group(owner: owner)
    create_membership(user: target, group: group, role: "manager")

    post "/api/v1/groups/#{group.id}/group_invites",
      params: { receivers: [target.name], role: "member" }, headers: auth_headers(owner)
    result = json_response["results"].first
    assert_equal "error", result["result"]
    assert_match "membership exists", result["message"]
  end

  test "create makes a real GroupInvite for an unmatched email" do
    owner = create_user
    group = create_group(owner: owner)

    assert_difference "GroupInvite.count", 1 do
      post "/api/v1/groups/#{group.id}/group_invites",
        params: { receivers: ["nobody@test.com"], role: "member" }, headers: auth_headers(owner)
    end
    assert_equal "invited", json_response["results"].first["result"]
    invite = GroupInvite.last
    assert_equal "sending", invite.status
    assert_equal "email", invite.receiver_address_type
    assert_equal "nobody@test.com", invite.receiver_address
  end

  test "create errors on an unmatched non-email handle" do
    owner = create_user
    group = create_group(owner: owner)

    post "/api/v1/groups/#{group.id}/group_invites",
      params: { receivers: ["not-a-handle-or-email"], role: "member" }, headers: auth_headers(owner)
    result = json_response["results"].first
    assert_equal "error", result["result"]
    assert_match "invalid receiver", result["message"]
  end

  test "create with an invalid role reports a per-address error instead of silently failing" do
    owner = create_user
    group = create_group(owner: owner)

    assert_no_difference "GroupInvite.count" do
      post "/api/v1/groups/#{group.id}/group_invites",
        params: { receivers: ["nobody@test.com"], role: "superadmin" }, headers: auth_headers(owner)
    end
    result = json_response["results"].first
    assert_equal "error", result["result"]
    assert_match "Role", result["message"]
  end

  test "create with an invalid role for a known-user role upgrade reports an error and does not change the role" do
    owner = create_user
    target = create_user
    group = create_group(owner: owner)
    create_membership(user: target, group: group, role: "member")

    post "/api/v1/groups/#{group.id}/group_invites",
      params: { receivers: [target.name], role: "superadmin" }, headers: auth_headers(owner)
    result = json_response["results"].first
    assert_equal "error", result["result"]
    assert_equal "member", group.memberships.find_by(user: target).role
  end

  test "create requires group admin" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)

    post "/api/v1/groups/#{group.id}/group_invites",
      params: { receivers: ["x@test.com"] }, headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "accept flips an email invite to accepted and grants membership" do
    owner = create_user
    invitee = create_user(email: "invitee@test.com")
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "invitee@test.com", expires_at: 30.days.from_now)

    post "/api/v1/groups/#{group.id}/group_invites/#{invite.id}/accept", headers: auth_headers(invitee)
    assert_response :success
    assert_equal "accepted", invite.reload.status
    assert group.memberships.exists?(user: invitee)
  end

  test "accept rejects a mismatched email" do
    owner = create_user
    invitee = create_user(email: "invitee@test.com")
    other = create_user(email: "someone-else@test.com")
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "invitee@test.com", expires_at: 30.days.from_now)

    post "/api/v1/groups/#{group.id}/group_invites/#{invite.id}/accept", headers: auth_headers(other)
    assert_response :unprocessable_entity
    assert_not group.memberships.exists?(user: other)
  end

  test "accept rejects an expired invite" do
    owner = create_user
    invitee = create_user(email: "invitee@test.com")
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "invitee@test.com", expires_at: 1.day.ago)

    post "/api/v1/groups/#{group.id}/group_invites/#{invite.id}/accept", headers: auth_headers(invitee)
    assert_response :unprocessable_entity
  end

  test "destroy cancels an invite (sender or admin)" do
    owner = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "x@test.com", expires_at: 30.days.from_now)

    delete "/api/v1/groups/#{group.id}/group_invites/#{invite.id}", headers: auth_headers(owner)
    assert_response :no_content
    assert_equal "cancelled", invite.reload.status
  end

  test "destroy lets the invite recipient decline their own email invite" do
    owner = create_user
    invitee = create_user(email: "invitee@test.com")
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "invitee@test.com", expires_at: 30.days.from_now)

    delete "/api/v1/groups/#{group.id}/group_invites/#{invite.id}", headers: auth_headers(invitee)
    assert_response :no_content
    assert_equal "cancelled", invite.reload.status
  end

  test "destroy lets a requester withdraw their own pending join request" do
    owner = create_user
    requester = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, receiver_id: requester.id, status: "requesting")

    delete "/api/v1/groups/#{group.id}/group_invites/#{invite.id}", headers: auth_headers(requester)
    assert_response :no_content
    assert_equal "cancelled", invite.reload.status
  end

  test "destroy still forbids an unrelated outsider" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "x@test.com", expires_at: 30.days.from_now)

    delete "/api/v1/groups/#{group.id}/group_invites/#{invite.id}", headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "show returns an email invite to its sender" do
    owner = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "x@test.com", expires_at: 30.days.from_now)

    get "/api/v1/group_invites/#{invite.id}", headers: auth_headers(owner)
    assert_response :success
    assert_equal invite.id, json_response["id"]
  end

  test "show returns an email invite to its matched recipient" do
    owner = create_user
    invitee = create_user(email: "invitee@test.com")
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "invitee@test.com", expires_at: 30.days.from_now)

    get "/api/v1/group_invites/#{invite.id}", headers: auth_headers(invitee)
    assert_response :success
  end

  test "show forbids an unrelated outsider from an email invite" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "x@test.com", expires_at: 30.days.from_now)

    get "/api/v1/group_invites/#{invite.id}", headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "show is open to any authenticated user for a reusable code invite" do
    owner = create_user
    stranger = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "code",
      receiver_address: "ABC12345", status: "sending", expires_at: 30.days.from_now)

    get "/api/v1/group_invites/#{invite.id}", headers: auth_headers(stranger)
    assert_response :success
  end

  test "show requires authentication" do
    owner = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "x@test.com", expires_at: 30.days.from_now)

    get "/api/v1/group_invites/#{invite.id}"
    assert_response :unauthorized
  end

  test "revoke also works to reject a pending join request" do
    owner = create_user
    requester = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, receiver_id: requester.id, status: "requesting")

    post "/api/v1/groups/#{group.id}/group_invites/#{invite.id}/revoke", headers: auth_headers(owner)
    assert_response :success
    assert_equal "revoked", invite.reload.status
    assert_not group.memberships.exists?(user: requester)
  end

  test "revoke forbids a non-sender, non-admin" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "x@test.com", expires_at: 30.days.from_now)

    post "/api/v1/groups/#{group.id}/group_invites/#{invite.id}/revoke", headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "request_invite creates a requesting invite" do
    user = create_user
    group = create_group

    post "/api/v1/groups/#{group.id}/group_invites/request_invite",
      params: { role: "member" }, headers: auth_headers(user)
    assert_response :created
    invite = GroupInvite.last
    assert_equal "requesting", invite.status
    assert_equal user.id, invite.receiver_id
  end

  test "request_invite rejects an existing member" do
    owner = create_user
    group = create_group(owner: owner)

    post "/api/v1/groups/#{group.id}/group_invites/request_invite", headers: auth_headers(owner)
    assert_response :unprocessable_entity
  end

  test "request_invite rejects a duplicate pending request" do
    user = create_user
    group = create_group

    post "/api/v1/groups/#{group.id}/group_invites/request_invite", headers: auth_headers(user)
    assert_response :created
    post "/api/v1/groups/#{group.id}/group_invites/request_invite", headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "request_invite sets a 30-day expiry" do
    user = create_user
    group = create_group

    post "/api/v1/groups/#{group.id}/group_invites/request_invite", headers: auth_headers(user)
    assert_response :created
    invite = GroupInvite.last
    assert invite.expires_at.present?
    assert_in_delta 30.days.from_now, invite.expires_at, 5.seconds
  end

  test "request_invite allows a fresh request once the prior one has expired" do
    user = create_user
    group = create_group
    stale = create_group_invite(group: group, receiver_id: user.id, status: "requesting", expires_at: 1.day.ago)

    post "/api/v1/groups/#{group.id}/group_invites/request_invite", headers: auth_headers(user)
    assert_response :created
    assert_equal "cancelled", stale.reload.status
  end

  test "accept_request rejects an expired join request" do
    owner = create_user
    requester = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, receiver_id: requester.id, status: "requesting", expires_at: 1.day.ago)

    post "/api/v1/groups/#{group.id}/group_invites/#{invite.id}/accept_request", headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_equal "requesting", invite.reload.status
    assert_not group.memberships.exists?(user: requester)
  end

  test "accept_request lets an admin approve a join request" do
    owner = create_user
    requester = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, receiver_id: requester.id, status: "requesting")

    post "/api/v1/groups/#{group.id}/group_invites/#{invite.id}/accept_request", headers: auth_headers(owner)
    assert_response :success
    assert_equal "accepted", invite.reload.status
    assert group.memberships.exists?(user: requester)
  end

  test "accept_request requires group admin" do
    owner = create_user
    requester = create_user
    group = create_group(owner: owner)
    invite = create_group_invite(group: group, receiver_id: requester.id, status: "requesting")

    post "/api/v1/groups/#{group.id}/group_invites/#{invite.id}/accept_request", headers: auth_headers(requester)
    assert_response :forbidden
  end

  test "send_with_code + accept_with_code — code stays reusable (never flips to accepted)" do
    owner = create_user
    joiner1 = create_user
    joiner2 = create_user
    group = create_group(owner: owner)

    post "/api/v1/groups/#{group.id}/group_invites/send_with_code",
      params: { role: "member" }, headers: auth_headers(owner)
    assert_response :created
    code = json_response["receiver_address"]

    post "/api/v1/groups/#{group.id}/group_invites/accept_with_code",
      params: { code: code }, headers: auth_headers(joiner1)
    assert_response :success
    assert group.memberships.exists?(user: joiner1)

    post "/api/v1/groups/#{group.id}/group_invites/accept_with_code",
      params: { code: code }, headers: auth_headers(joiner2)
    assert_response :success
    assert group.memberships.exists?(user: joiner2)

    invite = GroupInvite.find_by(receiver_address: code)
    assert_equal "sending", invite.status
  end

  test "accept_with_code rejects an invalid code" do
    owner = create_user
    joiner = create_user
    group = create_group(owner: owner)

    post "/api/v1/groups/#{group.id}/group_invites/accept_with_code",
      params: { code: "NOPE" }, headers: auth_headers(joiner)
    assert_response :unprocessable_entity
  end

  test "pending lists only sending-status email invites matching the current user's email" do
    owner = create_user
    invitee = create_user(email: "pending-invitee@test.com")
    group = create_group(owner: owner)
    create_group_invite(group: group, sender: owner, receiver_address_type: "email",
      receiver_address: "pending-invitee@test.com", expires_at: 30.days.from_now)

    get "/api/v1/group_invites/pending", headers: auth_headers(invitee)
    assert_response :success
    assert_equal 1, json_response.size
  end

  # --- phone whitelist invites ---------------------------------------------

  test "create with a phone number invites the number, normalized, without expiry" do
    owner = create_user
    group = create_group(owner: owner)

    assert_difference "GroupInvite.count", 1 do
      post "/api/v1/groups/#{group.id}/group_invites",
        params: { receivers: ["138 0013 8000"], role: "member" }, headers: auth_headers(owner)
    end
    assert_equal "invited", json_response["results"].first["result"]

    invite = GroupInvite.last
    assert_equal "phone", invite.receiver_address_type
    assert_equal "+8613800138000", invite.receiver_address
    assert_nil invite.expires_at
  end

  test "create with a phone number of an existing account adds them directly" do
    owner = create_user
    target = create_user
    target.update!(phone: "+8613800138001")
    group = create_group(owner: owner)

    assert_no_difference "GroupInvite.count" do
      post "/api/v1/groups/#{group.id}/group_invites",
        params: { receivers: ["13800138001"], role: "member" }, headers: auth_headers(owner)
    end
    assert_equal "added", json_response["results"].first["result"]
    assert group.memberships.exists?(user: target, role: "member")
  end

  test "re-importing a phone that is already pending does not duplicate the invite" do
    owner = create_user
    group = create_group(owner: owner)

    2.times do
      post "/api/v1/groups/#{group.id}/group_invites",
        params: { receivers: ["13800138002"], role: "member" }, headers: auth_headers(owner)
      assert_equal "invited", json_response["results"].first["result"]
    end
    assert_equal 1, GroupInvite.where(receiver_address: "+8613800138002").count
  end

  test "auto-accepting a member invite never demotes an existing manager" do
    owner = create_user
    group = create_group(owner: owner)
    manager = create_user
    manager.update!(phone: "+8613800138004")
    create_membership(user: manager, group: group, role: "manager")
    invite = GroupInvite.create!(
      group: group, sender: owner, role: "member",
      receiver_address_type: "phone", receiver_address: "+8613800138004", status: "sending"
    )

    GroupInvite.auto_accept_phone_invites_for(manager)

    assert_equal "manager", group.memberships.find_by(user: manager).role
    assert_equal "accepted", invite.reload.status
  end

  test "one broken invite does not block phone sign-in" do
    owner = create_user
    group = create_group(owner: owner)
    broken = GroupInvite.create!(
      group: group, sender: owner, role: "member",
      receiver_address_type: "phone", receiver_address: "+8613800138005", status: "sending"
    )
    user = User.create!(phone: "+8613800138005")

    # Auto-accept runs INSIDE sign-in, so an invite that blows up in accept!
    # must be contained — logged, left pending — rather than propagate.
    original = GroupInvite.instance_method(:accept!)
    GroupInvite.define_method(:accept!) { |_u| raise ActiveRecord::RecordInvalid.new(self) }
    begin
      assert_nothing_raised { GroupInvite.auto_accept_phone_invites_for(user) }
      assert_equal "sending", broken.reload.status
    ensure
      GroupInvite.define_method(:accept!, original)
    end
  end

  test "a phone invite auto-joins the group on SMS sign-in" do
    owner = create_user
    group = create_group(owner: owner)
    post "/api/v1/groups/#{group.id}/group_invites",
      params: { receivers: ["13800138003"], role: "member" }, headers: auth_headers(owner)

    ENV["PHONE_LOGIN_ENABLED"] = "true"
    post "/api/v1/auth/request_phone_code", params: { phone: "13800138003" }
    code = AuthCode.last.code
    post "/api/v1/auth/verify_phone_code", params: { phone: "13800138003", code: code }
    assert_response :success

    user = User.find_by(phone: "+8613800138003")
    assert group.memberships.exists?(user: user, role: "member")
    assert_equal "accepted", GroupInvite.find_by(receiver_address: "+8613800138003").status
  ensure
    ENV.delete("PHONE_LOGIN_ENABLED")
  end
end
