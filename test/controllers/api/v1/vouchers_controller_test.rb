require "test_helper"

class Api::V1::VouchersControllerTest < ActionDispatch::IntegrationTest
  # ---------- create ----------

  test "create mints a code-strategy voucher with an auto-generated code" do
    creator = create_user
    bc = create_badge_class(creator: creator)

    post "/api/v1/vouchers", params: { badge_class_id: bc.id }, headers: auth_headers(creator)
    assert_response :created
    assert_equal "code", json_response["strategy"]
    assert json_response["code"].present?
    assert_equal 65_535, json_response["counter"]
  end

  test "create honors an explicit counter" do
    creator = create_user
    bc = create_badge_class(creator: creator)

    post "/api/v1/vouchers", params: { badge_class_id: bc.id, counter: 5 }, headers: auth_headers(creator)
    assert_response :created
    assert_equal 5, json_response["counter"]
  end

  test "create requires BadgeClassPolicy#send? — non-creator without a group is forbidden" do
    creator = create_user
    outsider = create_user
    bc = create_badge_class(creator: creator)

    post "/api/v1/vouchers", params: { badge_class_id: bc.id }, headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "create rejects a value param on an unweighted badge class" do
    creator = create_user
    bc = create_badge_class(creator: creator, weighted: false)

    post "/api/v1/vouchers", params: { badge_class_id: bc.id, value: 10 }, headers: auth_headers(creator)
    assert_response :unprocessable_entity
  end

  test "create allows a value param on a weighted badge class" do
    creator = create_user
    bc = create_badge_class(creator: creator, weighted: true)

    post "/api/v1/vouchers", params: { badge_class_id: bc.id, value: 10 }, headers: auth_headers(creator)
    assert_response :created
  end

  test "create 404s for an unknown badge_class_id" do
    creator = create_user
    post "/api/v1/vouchers", params: { badge_class_id: "nope" }, headers: auth_headers(creator)
    assert_response :not_found
  end

  # ---------- send_badge (account strategy) ----------

  test "send_badge mints one single-use account-strategy voucher per resolved receiver" do
    creator = create_user
    receiver = create_user
    bc = create_badge_class(creator: creator)

    post "/api/v1/vouchers/send_badge", params: { badge_class_id: bc.id, receivers: [receiver.name] }, headers: auth_headers(creator)
    assert_response :created
    voucher = json_response.first
    assert_equal "account", voucher["strategy"]
    assert_equal receiver.id, voucher["receiver_id"]
    assert_equal 1, voucher["counter"]
  end

  test "send_badge resolves receivers by eth or email too" do
    creator = create_user
    receiver_by_eth = create_user(eth: "0x1111111111111111111111111111111111111111")
    receiver_by_email = create_user
    bc = create_badge_class(creator: creator)

    post "/api/v1/vouchers/send_badge",
      params: { badge_class_id: bc.id, receivers: [receiver_by_eth.eth, receiver_by_email.email] },
      headers: auth_headers(creator)
    assert_response :created
    ids = json_response.map { |v| v["receiver_id"] }
    assert_includes ids, receiver_by_eth.id
    assert_includes ids, receiver_by_email.id
  end

  test "send_badge rejects an unresolvable receiver" do
    creator = create_user
    bc = create_badge_class(creator: creator)

    post "/api/v1/vouchers/send_badge", params: { badge_class_id: bc.id, receivers: ["nobody-like-this"] }, headers: auth_headers(creator)
    assert_response :unprocessable_entity
  end

  test "send_badge on a group badge_class is allowed for a group admin who isn't the creator" do
    owner = create_user
    admin = create_user
    receiver = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")
    bc = create_badge_class(creator: owner, group: group)

    post "/api/v1/vouchers/send_badge", params: { badge_class_id: bc.id, receivers: [receiver.name] }, headers: auth_headers(admin)
    assert_response :created
  end

  test "send_badge on a group badge_class is forbidden for an ordinary member" do
    owner = create_user
    member = create_user
    receiver = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    bc = create_badge_class(creator: owner, group: group)

    post "/api/v1/vouchers/send_badge", params: { badge_class_id: bc.id, receivers: [receiver.name] }, headers: auth_headers(member)
    assert_response :forbidden
  end

  test "send_badge with group_member_send lets an ordinary member send" do
    owner = create_user
    member = create_user
    receiver = create_user
    group = create_group(owner: owner)
    create_membership(user: member, group: group, role: "member")
    bc = create_badge_class(creator: owner, group: group, can_send_badge: "group_member_send")

    post "/api/v1/vouchers/send_badge", params: { badge_class_id: bc.id, receivers: [receiver.name] }, headers: auth_headers(member)
    assert_response :created
  end

  # ---------- send_badge_by_address (address strategy) ----------

  test "send_badge_by_address mints an address-strategy voucher for a valid 0x address" do
    creator = create_user
    bc = create_badge_class(creator: creator)
    address = "0x" + "a" * 40

    post "/api/v1/vouchers/send_badge_by_address", params: { badge_class_id: bc.id, receivers: [address] }, headers: auth_headers(creator)
    assert_response :created
    voucher = json_response.first
    assert_equal "address", voucher["strategy"]
    assert_equal address, voucher["receiver_address"]
  end

  test "send_badge_by_address rejects a malformed address" do
    creator = create_user
    bc = create_badge_class(creator: creator)

    post "/api/v1/vouchers/send_badge_by_address", params: { badge_class_id: bc.id, receivers: ["not-an-address"] }, headers: auth_headers(creator)
    assert_response :unprocessable_entity
  end

  # ---------- send_badge_by_email (email strategy) ----------

  test "send_badge_by_email mints an email-strategy voucher for a valid email" do
    creator = create_user
    bc = create_badge_class(creator: creator)

    post "/api/v1/vouchers/send_badge_by_email", params: { badge_class_id: bc.id, receivers: ["someone@test.com"] }, headers: auth_headers(creator)
    assert_response :created
    voucher = json_response.first
    assert_equal "email", voucher["strategy"]
    assert_equal "someone@test.com", voucher["receiver_address"]
  end

  test "send_badge_by_email also accepts a raw address" do
    creator = create_user
    bc = create_badge_class(creator: creator)
    address = "0x" + "b" * 40

    post "/api/v1/vouchers/send_badge_by_email", params: { badge_class_id: bc.id, receivers: [address] }, headers: auth_headers(creator)
    assert_response :created
  end

  test "send_badge_by_email rejects garbage input" do
    creator = create_user
    bc = create_badge_class(creator: creator)

    post "/api/v1/vouchers/send_badge_by_email", params: { badge_class_id: bc.id, receivers: ["garbage"] }, headers: auth_headers(creator)
    assert_response :unprocessable_entity
  end

  # ---------- use: code strategy ----------

  test "use redeems a code-strategy voucher with the correct code" do
    creator = create_user
    claimer = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 3)

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer)
    assert_response :success
    assert_equal "minted", json_response["status"]
    badge = Badge.find(json_response["id"])
    assert_equal claimer.id, badge.owner_id
    assert_equal voucher.id, badge.voucher_id
  end

  test "use rejects an incorrect code" do
    creator = create_user
    claimer = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 3)

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "WRONG" }, headers: auth_headers(claimer)
    assert_response :unprocessable_entity
    assert_equal 0, Badge.where(voucher_id: voucher.id).count
  end

  test "a counter>1 code voucher can be claimed by multiple different users" do
    creator = create_user
    claimer1 = create_user
    claimer2 = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 3)

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer1)
    assert_response :success
    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer2)
    assert_response :success

    assert_equal 2, Badge.where(voucher_id: voucher.id).count
    assert_equal 1, voucher.reload.counter
  end

  test "use rejects a double-claim by the same user" do
    creator = create_user
    claimer = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 5)

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer)
    assert_response :success

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer)
    assert_response :unprocessable_entity
    assert_equal 1, Badge.where(voucher_id: voucher.id, owner_id: claimer.id).count
  end

  test "use rejects an expired voucher" do
    creator = create_user
    claimer = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 3, expires_at: 1.day.ago)

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer)
    assert_response :unprocessable_entity
  end

  test "use rejects a counter-exhausted voucher" do
    creator = create_user
    claimer = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 0)

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer)
    assert_response :unprocessable_entity
  end

  # ---------- use: account strategy ----------

  test "use redeems an account-strategy voucher only for the designated receiver" do
    creator = create_user
    receiver = create_user
    outsider = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "account", receiver_id: receiver.id, counter: 1)

    post "/api/v1/vouchers/#{voucher.id}/use", headers: auth_headers(outsider)
    assert_response :unprocessable_entity

    post "/api/v1/vouchers/#{voucher.id}/use", headers: auth_headers(receiver)
    assert_response :success
  end

  # ---------- use: address strategy ----------

  test "use redeems an address-strategy voucher only when receiver_address matches current_user.eth" do
    creator = create_user
    address = "0x" + "c" * 40
    owner_of_address = create_user(eth: address)
    outsider = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "address", receiver_address: address, counter: 1)

    post "/api/v1/vouchers/#{voucher.id}/use", headers: auth_headers(outsider)
    assert_response :unprocessable_entity

    post "/api/v1/vouchers/#{voucher.id}/use", headers: auth_headers(owner_of_address)
    assert_response :success
  end

  # ---------- use: email strategy ----------

  test "use redeems an email-strategy voucher only when receiver_address matches current_user.email" do
    creator = create_user
    matching_user = create_user(email: "match-me@test.com")
    outsider = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "email", receiver_address: "match-me@test.com", counter: 1)

    post "/api/v1/vouchers/#{voucher.id}/use", headers: auth_headers(outsider)
    assert_response :unprocessable_entity

    post "/api/v1/vouchers/#{voucher.id}/use", headers: auth_headers(matching_user)
    assert_response :success
  end

  # ---------- use: event strategy ----------

  test "use redeems an event-strategy voucher and links the minted badge back onto the Participant" do
    creator = create_user
    attendee = create_user
    group = create_group(owner: creator)
    event = create_event(group: group, owner: creator)
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "event", receiver_id: attendee.id, counter: 1)
    participant = create_participant(event: event, user: attendee, voucher_id: voucher.id)

    post "/api/v1/vouchers/#{voucher.id}/use", headers: auth_headers(attendee)
    assert_response :success

    badge_id = json_response["id"]
    assert_equal badge_id, participant.reload.badge_id
  end

  # ---------- use: badge_class.counter / badge.index semantics ----------

  test "use captures badge.index from badge_class.counter before incrementing it" do
    creator = create_user
    claimer = create_user
    bc = create_badge_class(creator: creator, counter: 7)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 1)

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer)
    assert_response :success
    assert_equal 7, json_response["index"]
    assert_equal 8, bc.reload.counter
  end

  # ---------- use: voucher.data jsonb copied onto the badge ----------

  test "use copies value/start_time/end_time out of voucher.data onto the minted badge" do
    creator = create_user
    claimer = create_user
    bc = create_badge_class(creator: creator, weighted: true)
    start_time = 1.day.from_now
    end_time = 2.days.from_now
    voucher = create_voucher(
      sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 1,
      data: { value: 42, start_time: start_time, end_time: end_time }
    )

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer)
    assert_response :success
    assert_equal 42, json_response["value"]
    assert json_response["start_time"].present?
    assert json_response["end_time"].present?
  end

  # ---------- use: group_member_pass permission ----------

  test "use with a group_member_pass badge_class auto-joins the redeemer to the group" do
    creator = create_user
    claimer = create_user
    group = create_group(owner: creator)
    bc = create_badge_class(creator: creator, group: group, permissions: ["group_member_pass"])
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 1)

    assert_not group.memberships.exists?(user: claimer)
    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer)
    assert_response :success
    assert group.memberships.exists?(user: claimer, role: "member")
  end

  test "use with group_member_pass is idempotent when already a member" do
    creator = create_user
    claimer = create_user
    group = create_group(owner: creator)
    bc = create_badge_class(creator: creator, group: group, permissions: ["group_member_pass"])
    create_membership(user: claimer, group: group, role: "manager")
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 1)

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer)
    assert_response :success
    # find_or_create_by must not touch the existing admin role
    assert_equal "manager", group.memberships.find_by(user: claimer).role
  end

  # ---------- get_code ----------

  test "get_code is sender-only" do
    creator = create_user
    outsider = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, code: "SECRET1")

    get "/api/v1/vouchers/#{voucher.id}/code", headers: auth_headers(outsider)
    assert_response :forbidden

    get "/api/v1/vouchers/#{voucher.id}/code", headers: auth_headers(creator)
    assert_response :success
    assert_equal "SECRET1", json_response["code"]
  end

  # ---------- revoke ----------

  test "revoke is sender-only and zeroes the counter, blocking further use" do
    creator = create_user
    outsider = create_user
    claimer = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 3)

    post "/api/v1/vouchers/#{voucher.id}/revoke", headers: auth_headers(outsider)
    assert_response :forbidden

    post "/api/v1/vouchers/#{voucher.id}/revoke", headers: auth_headers(creator)
    assert_response :success
    assert_equal 0, voucher.reload.counter

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer)
    assert_response :unprocessable_entity
  end

  # ---------- reject_badge ----------

  test "reject_badge only works for the account-strategy designated receiver" do
    creator = create_user
    receiver = create_user
    outsider = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "account", receiver_id: receiver.id, counter: 1)

    post "/api/v1/vouchers/#{voucher.id}/reject_badge", headers: auth_headers(outsider)
    assert_response :unprocessable_entity
    assert_not_equal 0, voucher.reload.counter

    post "/api/v1/vouchers/#{voucher.id}/reject_badge", headers: auth_headers(receiver)
    assert_response :success
    assert_equal 0, voucher.reload.counter
  end

  test "reject_badge rejects a non-account-strategy voucher even for the matching receiver_id" do
    creator = create_user
    receiver = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "event", receiver_id: receiver.id, counter: 1)

    post "/api/v1/vouchers/#{voucher.id}/reject_badge", headers: auth_headers(receiver)
    assert_response :unprocessable_entity
  end

  # ---------- index / show ----------

  test "index filters out expired and counter-exhausted vouchers" do
    creator = create_user
    bc = create_badge_class(creator: creator)
    active = create_voucher(sender: creator, badge_class: bc, counter: 3)
    create_voucher(sender: creator, badge_class: bc, counter: 0)
    create_voucher(sender: creator, badge_class: bc, counter: 3, expires_at: 1.day.ago)

    get "/api/v1/vouchers", headers: auth_headers(creator)
    assert_response :success
    ids = json_response["data"].map { |v| v["id"] }
    assert_includes ids, active.id
    assert_equal 1, ids.size
  end

  test "index filters by sender_handle" do
    sender1 = create_user
    sender2 = create_user
    bc1 = create_badge_class(creator: sender1)
    bc2 = create_badge_class(creator: sender2)
    v1 = create_voucher(sender: sender1, badge_class: bc1, counter: 3)
    create_voucher(sender: sender2, badge_class: bc2, counter: 3)

    get "/api/v1/vouchers", params: { sender_handle: sender1.name }, headers: auth_headers(sender1)
    assert_response :success
    ids = json_response["data"].map { |v| v["id"] }
    assert_equal [v1.id], ids
  end

  # This branch joins badge_classes, which has its own `counter` column. With
  # the filter above written unqualified, Postgres raised AmbiguousColumn and
  # the endpoint 500'd — taking the group page's "Sending" tab down with it.
  # It went unnoticed because nothing exercised group_handle at all.
  test "index filters by group_handle" do
    creator = create_user
    group = create_group(owner: creator)
    other_group = create_group(owner: creator)
    bc = create_badge_class(creator: creator, group: group)
    other_bc = create_badge_class(creator: creator, group: other_group)
    mine = create_voucher(sender: creator, badge_class: bc, counter: 3)
    create_voucher(sender: creator, badge_class: other_bc, counter: 3)

    get "/api/v1/vouchers", params: { group_handle: group.name }
    assert_response :success
    assert_equal [mine.id], json_response["data"].map { |v| v["id"] }
  end

  # The 500 fired even with nothing to return, since the ambiguity is in the
  # SQL rather than in any row — which is exactly the state a brand-new group
  # is in, and the one a group page hits first.
  test "index by group_handle succeeds for a group with no vouchers" do
    creator = create_user
    group = create_group(owner: creator)

    get "/api/v1/vouchers", params: { group_handle: group.name }
    assert_response :success
    assert_empty json_response["data"]
  end

  test "index by group_handle still applies the expiry and counter filters" do
    creator = create_user
    group = create_group(owner: creator)
    bc = create_badge_class(creator: creator, group: group)
    live = create_voucher(sender: creator, badge_class: bc, counter: 3)
    create_voucher(sender: creator, badge_class: bc, counter: 0)
    create_voucher(sender: creator, badge_class: bc, counter: 3, expires_at: 1.day.ago)

    get "/api/v1/vouchers", params: { group_handle: group.name }
    assert_response :success
    assert_equal [live.id], json_response["data"].map { |v| v["id"] }
  end

  test "show renders the voucher with its badges" do
    creator = create_user
    claimer = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "SECRET1", counter: 1)
    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "SECRET1" }, headers: auth_headers(claimer)
    assert_response :success

    get "/api/v1/vouchers/#{voucher.id}", headers: auth_headers(creator)
    assert_response :success
    assert_equal 1, json_response["badges"].size
  end

  # ---------- regressions (code-review fixes) ----------

  test "send_badge is atomic: one invalid receiver in the batch commits nothing" do
    creator = create_user
    valid = create_user
    bc = create_badge_class(creator: creator)

    assert_no_difference "Voucher.count" do
      post "/api/v1/vouchers/send_badge",
        params: { badge_class_id: bc.id, receivers: [valid.name, "no-such-user"] },
        headers: auth_headers(creator)
    end
    assert_response :unprocessable_entity
    assert_match "invalid receiver", json_response["error"]
  end

  test "send_badge_by_address rejects a value for an unweighted badge (guard no longer only on send_badge)" do
    creator = create_user
    bc = create_badge_class(creator: creator, weighted: false)

    post "/api/v1/vouchers/send_badge_by_address",
      params: { badge_class_id: bc.id, receivers: ["0x" + "a" * 40], value: 50 },
      headers: auth_headers(creator)
    assert_response :unprocessable_entity
    assert_match "unweighted", json_response["error"]
  end

  test "use default-denies a strategy with no eligibility rule (remember)" do
    creator = create_user
    claimer = create_user
    bc = create_badge_class(creator: creator)
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "remember", counter: 1)

    assert_no_difference "Badge.count" do
      post "/api/v1/vouchers/#{voucher.id}/use", headers: auth_headers(claimer)
    end
    assert_response :unprocessable_entity
    assert_match "cannot be redeemed", json_response["error"]
  end

  test "use auto-joins the group when badge_class carries group_member_pass" do
    creator = create_user
    claimer = create_user
    group = create_group(owner: creator)
    bc = create_badge_class(creator: creator, group: group, permissions: ["group_member_pass"])
    voucher = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "JOINME", counter: 1)

    post "/api/v1/vouchers/#{voucher.id}/use", params: { code: "JOINME" }, headers: auth_headers(claimer)
    assert_response :success
    assert group.memberships.exists?(user: claimer), "claimer should be auto-added to the group"
  end

  test "use assigns distinct badge indexes across vouchers of the same class" do
    creator = create_user
    u1 = create_user
    u2 = create_user
    bc = create_badge_class(creator: creator)
    v1 = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "C1", counter: 1)
    v2 = create_voucher(sender: creator, badge_class: bc, strategy: "code", code: "C2", counter: 1)

    post "/api/v1/vouchers/#{v1.id}/use", params: { code: "C1" }, headers: auth_headers(u1)
    idx1 = json_response["index"]
    post "/api/v1/vouchers/#{v2.id}/use", params: { code: "C2" }, headers: auth_headers(u2)
    idx2 = json_response["index"]

    assert_not_equal idx1, idx2
    assert_equal 3, bc.reload.counter # started at 1, +1 per redemption
  end
end
