require "test_helper"

class Api::V1::Mini706Test < ActionDispatch::IntegrationTest
  test "wechat miniprogram login creates a user and never writes the official-account openid" do
    WechatMiniSession.stub(:exchange, { "openid" => "mini-openid-1", "unionid" => "union-1" }) do
      post "/api/v1/auth/wechat_miniprogram", params: { js_code: "code-1" }
    end
    assert_response :success
    user = User.find(json_response.dig("user", "id"))
    assert json_response["token"].present?
    assert_equal "mini-openid-1", user.wechat_mini_openid
    assert_equal "union-1", user.wechat_unionid
    assert_nil user.wechat_openid

    WechatMiniSession.stub(:exchange, { "openid" => "mini-openid-1", "unionid" => "union-1" }) do
      post "/api/v1/auth/wechat_miniprogram", params: { js_code: "code-2" }
    end
    assert_response :success
    assert_equal user.id, json_response.dig("user", "id")
    assert_equal 1, User.where(wechat_mini_openid: "mini-openid-1").count
  end

  test "wechat miniprogram login attaches a mini openid onto the unionid account" do
    existing = create_user(wechat_unionid: "union-existing")
    WechatMiniSession.stub(:exchange, { "openid" => "mini-attached", "unionid" => "union-existing" }) do
      post "/api/v1/auth/wechat_miniprogram", params: { js_code: "code-3" }
    end
    assert_response :success
    assert_equal existing.id, json_response.dig("user", "id")
    existing.reload
    assert_equal "mini-attached", existing.wechat_mini_openid
    assert_nil existing.wechat_openid
  end

  test "wechat miniprogram login reports a blank code, a missing app, and a failed exchange" do
    post "/api/v1/auth/wechat_miniprogram", params: { js_code: "  " }
    assert_response :unprocessable_entity

    unconfigured = ->(*) { raise WechatMiniSession::Error, "not configured" }
    WechatMiniSession.stub(:exchange, unconfigured) do
      post "/api/v1/auth/wechat_miniprogram", params: { js_code: "code" }
    end
    assert_response :service_unavailable
    assert_equal "miniprogram login is not configured", json_response["error"]

    failed = ->(*) { raise WechatMiniSession::Error, "wechat login failed" }
    WechatMiniSession.stub(:exchange, failed) do
      post "/api/v1/auth/wechat_miniprogram", params: { js_code: "code" }
    end
    assert_response :unprocessable_entity
    assert_equal "wechat login failed", json_response["error"]
  end

  test "profile data merges whitelisted keys and keeps the rest" do
    user = create_user
    user.update!(data: { "kept" => "yes" })

    patch "/api/v1/users/#{user.id}",
      params: { user: { data: { city: "shanghai", interests: [ "music" ], contact: { wechat: "wxid" }, secret: "no" } } },
      headers: auth_headers(user), as: :json
    assert_response :success

    patch "/api/v1/users/#{user.id}",
      params: { user: { data: { introduction: "hello" } } },
      headers: auth_headers(user), as: :json
    assert_response :success

    get "/api/v1/users/#{user.id}", headers: auth_headers(user)
    assert_equal "shanghai", json_response["city"]
    assert_equal [ "music" ], json_response["interests"]
    assert_equal "hello", json_response["introduction"]
    assert_equal "wxid", json_response.dig("contact", "wechat")
    assert_equal "yes", user.reload.data["kept"]
    assert_nil user.data["secret"]
    assert_not json_response.key?("wechat_mini_openid")
  end

  test "group city and card data are public, and public_contact is manager-only" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner, city: "shanghai")
    other = create_group(owner: owner, city: "beijing")

    patch "/api/v1/groups/#{group.id}",
      params: { group: { data: { opening_hours: "10-18", address: "Nanjing Rd", public_contact: "wx-host", allow_event_requests: true } } },
      headers: auth_headers(owner), as: :json
    assert_response :success

    get "/api/v1/groups/directory", params: { city: "shanghai" }
    assert_response :success
    assert_equal [ group.id ], json_response["data"].map { |row| row["id"] }
    card = json_response["data"].first
    assert_equal "shanghai", card["city"]
    assert_equal "10-18", card["opening_hours"]
    assert_equal "Nanjing Rd", card["address"]
    assert_equal true, card["allow_event_requests"]
    assert_not card.key?("public_contact")
    assert_not json_response["data"].map { |row| row["id"] }.include?(other.id)

    get "/api/v1/groups/#{group.id}", headers: auth_headers(outsider)
    assert_not json_response.key?("public_contact")
    assert json_response.key?("followers_count")

    get "/api/v1/groups/#{group.id}", headers: auth_headers(owner)
    assert_equal "wx-host", json_response["public_contact"]
  end

  test "event lists expose city and the wechat ticket price" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", city: "shanghai")
    create_event(group: group, owner: owner, status: "published", city: "beijing")
    ticket = create_ticket(event: event)
    setting = create_wechat_pay_setting
    create_payment_method(item: ticket, chain: "wechat", kind: "fiat", price: 2000, currency: "cny", wechat_pay_setting_id: setting.id)
    create_payment_method(item: ticket, chain: "base", kind: "crypto", price: 1, chains: [ "base" ], token_address: "0x1", receiver_address: "0x2")

    get "/api/v1/events", params: { city: "shanghai", group_id: group.id }
    assert_response :success
    row = json_response["data"].find { |item| item["id"] == event.id }
    assert_equal "shanghai", row["city"]
    assert_equal 2000, row["ticket_price"]
    assert_equal "cny", row["ticket_currency"]
    assert_equal true, row["has_non_wechat_price"]
    assert_equal [ event.id ], json_response["data"].map { |item| item["id"] }
  end

  test "the public roster is confirmed attendees, and status filters are manager-only" do
    owner = create_user
    confirmed = create_user
    waiting = create_user
    unpaid = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published")
    create_participant(event: event, user: confirmed, status: "attending", message: "see you")
    create_participant(event: event, user: waiting, status: "pending", message: "please")
    create_participant(event: event, user: unpaid, status: "attending", payment_status: "pending")

    get "/api/v1/events/#{event.id}/participants"
    assert_response :success
    assert_equal [ confirmed.id ], json_response["data"].map { |row| row.dig("user", "id") }
    assert_not json_response["data"].first.key?("message")

    get "/api/v1/events/#{event.id}/participants", params: { status: "pending" }
    assert_response :forbidden

    get "/api/v1/events/#{event.id}/participants", params: { status: "nope" }, headers: auth_headers(owner)
    assert_response :unprocessable_entity

    get "/api/v1/events/#{event.id}/participants", params: { status: "pending" }, headers: auth_headers(owner)
    assert_response :success
    assert_equal [ waiting.id ], json_response["data"].map { |row| row.dig("user", "id") }
    assert_equal "please", json_response["data"].first["message"]

    get "/api/v1/events/#{event.id}", headers: auth_headers(owner)
    assert_equal [ confirmed.id ], json_response["participants"].map { |row| row.dig("user", "id") }
  end

  test "a paid event rejects a free join, and a paid order cannot be ordered or cancelled again" do
    owner = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    ticket = create_ticket(event: event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1500)

    assert_no_difference "Participant.count" do
      post "/api/v1/events/#{event.id}/participants", headers: auth_headers(owner)
    end
    assert_response :unprocessable_entity
    assert_equal "paid event requires a ticket", json_response["error"]

    post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    assert_response :success
    item = TicketItem.find(json_response["ticket_item"]["id"])
    participant = Participant.find(json_response["participant"]["id"])
    item.confirm_payment!(txhash: "pi_once")

    post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_equal "you already have a paid order for this ticket", json_response["error"]
    assert_equal 1, TicketItem.where(user: buyer, ticket: ticket).count

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_equal "refund required before cancel", json_response["error"]

    delete "/api/v1/events/#{event.id}", headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_equal "refund required before cancel", json_response["error"]
    assert_equal "draft", event.reload.status
  end

  test "a free join records a registration message for the attendee" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)

    post "/api/v1/events/#{event.id}/participants",
      params: { participant: { message: "coming" } }, headers: auth_headers(attendee)
    assert_response :created
    assert_equal "coming", json_response["message"]
    assert Activity.exists?(receiver_id: attendee.id, action: "registration/confirmed")
  end

  test "invite and membership paths do not grant owner or overwrite a role" do
    owner = create_user
    manager = create_user
    member = create_user
    joiner = create_user
    group = create_group(owner: owner)
    create_membership(user: manager, group: group, role: "manager")
    create_membership(user: member, group: group, role: "member")

    post "/api/v1/groups/#{group.id}/group_invites",
      params: { receivers: [ joiner.name ], role: "owner" }, headers: auth_headers(manager)
    assert_response :forbidden
    assert_equal "only an owner can grant the owner role", json_response["error"]

    post "/api/v1/groups/#{group.id}/group_invites/send_with_code",
      params: { role: "owner" }, headers: auth_headers(manager)
    assert_response :forbidden

    post "/api/v1/groups/#{group.id}/memberships",
      params: { user_id: member.id, role: "manager" }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_equal "membership exists", json_response["error"]
    assert_equal "member", Membership.find_by(user: member, group: group).role

    post "/api/v1/groups/#{group.id}/group_invites/send_with_code",
      params: { role: "manager" }, headers: auth_headers(owner)
    assert_response :created
    code = json_response["receiver_address"]

    post "/api/v1/groups/#{group.id}/group_invites/accept_with_code",
      params: { code: code }, headers: auth_headers(joiner)
    assert_response :success
    assert_equal "manager", Membership.find_by(user: joiner, group: group).role

    post "/api/v1/groups/#{group.id}/group_invites/accept_with_code",
      params: { code: code }, headers: auth_headers(joiner)
    assert_response :unprocessable_entity
    assert_equal "membership exists", json_response["error"]
    assert_equal "manager", Membership.find_by(user: joiner, group: group).role
    assert_equal 0, Activity.where(initiator: joiner, action: "group_invite/update_role").count
  end

  test "follows can be repeated without a second row, and there is no feed route" do
    user = create_user
    target = create_user
    group = create_group(owner: user)

    post "/api/v1/follows", params: { target_type: "User", target_id: user.id }, headers: auth_headers(user)
    assert_response :unprocessable_entity

    post "/api/v1/follows", params: { target_type: "User", target_id: target.id }, headers: auth_headers(user)
    assert_response :created
    follow_id = json_response["id"]

    post "/api/v1/follows", params: { target_type: "User", target_id: target.id }, headers: auth_headers(user)
    assert_response :success
    assert_equal follow_id, json_response["id"]
    assert_equal 1, Follow.where(user: user, target_id: target.id).count

    post "/api/v1/follows", params: { target_type: "Group", target_id: group.id }, headers: auth_headers(user)
    assert_response :created

    delete "/api/v1/follows/#{follow_id}", headers: auth_headers(user)
    assert_response :no_content
    assert_equal "inactive", Follow.find(follow_id).status

    get "/api/v1/follows", headers: auth_headers(user)
    assert_equal [ "Group" ], json_response["data"].map { |row| row["target_type"] }

    get "/api/v1/users/#{target.id}"
    assert_equal 0, json_response["followers_count"]

    get "/api/v1/follows/feed", headers: auth_headers(user)
    assert_response :success
    assert_empty json_response["data"]
  end

  test "blocking hides that person's recommendations from the blocker" do
    reader = create_user
    author = create_user
    group = create_group(owner: reader)
    event = create_event(group: group, owner: reader, status: "published")
    comment = create_comment(user: author, item: event, comment_type: "recommendation")

    post "/api/v1/blocks", params: { target_user_id: author.id }, headers: auth_headers(reader)
    assert_response :created
    first_id = json_response["id"]

    get "/api/v1/comments", params: { comment_type: "recommendation", item_type: "Event", item_id: event.id },
      headers: auth_headers(reader)
    assert_empty json_response["data"]

    get "/api/v1/comments", params: { comment_type: "recommendation", item_type: "Event", item_id: event.id }
    assert_equal [ comment.id ], json_response["data"].map { |row| row["id"] }

    delete "/api/v1/blocks/#{first_id}", headers: auth_headers(reader)
    assert_response :no_content

    post "/api/v1/blocks", params: { target_user_id: author.id }, headers: auth_headers(reader)
    assert_response :created
    assert_not_equal first_id, json_response["id"]
    assert_equal 1, Block.where(user: reader, target_user: author).count
  end

  test "reports can be filed by anyone and resolved only by a platform admin" do
    user = create_user
    admin = create_user
    admin.update!(admin: true)

    post "/api/v1/reports", params: { report: { target_type: "User", target_id: admin.id, reason: "spam" } },
      headers: auth_headers(user)
    assert_response :created
    report_id = json_response["id"]
    assert_equal "open", json_response["status"]

    get "/api/v1/reports", headers: auth_headers(user)
    assert_response :forbidden

    get "/api/v1/reports", headers: auth_headers(admin)
    assert_response :success
    assert_equal [ report_id ], json_response["data"].map { |row| row["id"] }

    post "/api/v1/reports/#{report_id}/resolve", params: { status: "resolved", note: "done" }, headers: auth_headers(admin)
    assert_response :success
    assert_equal "resolved", json_response["status"]
    assert_equal "done", json_response["note"]
  end

  test "the campaign creator reviews, and public event ids stay the published intersection" do
    creator = create_user
    host = create_user
    group = create_group(owner: creator)
    published = create_event(group: group, owner: host, status: "published", title: "Live")
    draft = create_event(group: group, owner: host, status: "draft")

    post "/api/v1/campaigns",
      params: { campaign: { title: "Week", group_id: group.id, event_ids: [ published.id, draft.id ] } },
      headers: auth_headers(creator), as: :json
    assert_response :unprocessable_entity

    post "/api/v1/campaigns",
      params: { campaign: { title: "Week", group_id: group.id, event_ids: [ published.id, published.id ], resource_links: [ "https://706.city/week" ] } },
      headers: auth_headers(creator), as: :json
    assert_response :created
    campaign_id = json_response["id"]
    assert_equal "draft", json_response["status"]
    assert_equal [ published.id ], json_response["event_ids"]
    assert_equal [ "https://706.city/week" ], json_response["resource_links"]

    post "/api/v1/campaigns/#{campaign_id}/submit", headers: auth_headers(creator)
    assert_response :success
    assert_equal "in_review", json_response["status"]

    get "/api/v1/reviews", params: { status: "pending" }, headers: auth_headers(creator)
    review_id = json_response["data"].first["id"]

    patch "/api/v1/campaigns/#{campaign_id}",
      params: { campaign: { title: "Week two" } }, headers: auth_headers(creator), as: :json
    assert_response :success
    assert_equal 2, json_response["round"]
    assert_equal "superseded", Review.find(review_id).status

    get "/api/v1/reviews", params: { status: "pending" }, headers: auth_headers(creator)
    fresh_id = json_response["data"].first["id"]
    post "/api/v1/reviews/#{fresh_id}/decide", params: { decision: "approved" }, headers: auth_headers(creator)
    assert_response :success
    assert_equal "approved", json_response["status"]
    assert Activity.exists?(receiver_id: host.id, action: "campaign/published")

    get "/api/v1/campaigns/#{campaign_id}"
    assert_equal [ published.id ], json_response["event_ids"]

    published.update!(status: "cancelled")
    get "/api/v1/campaigns/#{campaign_id}"
    assert_empty json_response["event_ids"]

    get "/api/v1/campaigns/#{campaign_id}", headers: auth_headers(creator)
    assert_equal [ published.id ], json_response["event_ids"]
    assert_equal "cancelled", json_response["event_statuses"].first["status"]
  end

  test "a platform admin can grant and revoke admin, and cannot remove their own" do
    admin = create_user(admin: true)
    member = create_user
    other = create_user(permissions: [ "admin" ])

    get "/api/v1/platform_admins", headers: auth_headers(member)
    assert_response :forbidden

    get "/api/v1/platform_admins", headers: auth_headers(admin)
    assert_response :success
    ids = json_response["data"].map { |row| row["id"] }
    assert_includes ids, admin.id
    assert_includes ids, other.id
    assert_not_includes ids, member.id

    patch "/api/v1/users/#{member.id}", params: { user: { admin: true } }, headers: auth_headers(member), as: :json
    assert_response :success
    assert_not member.reload.admin?

    post "/api/v1/platform_admins", params: { user_id: member.id }, headers: auth_headers(member), as: :json
    assert_response :forbidden
    assert_not member.reload.admin?

    post "/api/v1/platform_admins", params: { user_id: member.id }, headers: auth_headers(admin), as: :json
    assert_response :created
    assert member.reload.admin?
    assert_not_includes member.permissions, "admin"
    assert_equal true, json_response["admin"]

    delete "/api/v1/platform_admins/#{admin.id}", headers: auth_headers(admin)
    assert_response :unprocessable_entity
    assert admin.reload.admin?

    delete "/api/v1/platform_admins/#{other.id}", headers: auth_headers(admin)
    assert_response :no_content
    other.reload
    assert_not other.admin?
    assert_not_includes other.permissions, "admin"

    delete "/api/v1/platform_admins/#{member.id}", headers: auth_headers(admin)
    assert_response :no_content
    assert_not member.reload.admin?
  end

  test "the campaign owner can delete the series and its reviews without deleting events" do
    creator = create_user
    other = create_user
    group = create_group(owner: creator)
    event = create_event(group: group, owner: creator, status: "published", title: "Live")

    post "/api/v1/campaigns",
      params: { campaign: { title: "Week", event_ids: [ event.id ] } },
      headers: auth_headers(creator), as: :json
    assert_response :created
    campaign_id = json_response["id"]
    post "/api/v1/campaigns/#{campaign_id}/submit", headers: auth_headers(creator)
    assert_response :success
    assert Review.exists?(campaign_id: campaign_id)

    delete "/api/v1/campaigns/#{campaign_id}", headers: auth_headers(other)
    assert_response :forbidden
    assert Campaign.exists?(campaign_id)

    delete "/api/v1/campaigns/#{campaign_id}", headers: auth_headers(creator)
    assert_response :no_content
    assert_not Campaign.exists?(campaign_id)
    assert_not Review.exists?(campaign_id: campaign_id)
    assert Event.exists?(event.id)

    delete "/api/v1/campaigns/#{campaign_id}", headers: auth_headers(creator)
    assert_response :not_found
  end

  test "a group manager can refund an event ticket, and a member cannot" do
    owner = create_user
    manager = create_user
    member = create_user
    buyer = create_user
    group = create_group(owner: owner)
    create_membership(user: manager, group: group, role: "manager")
    create_membership(user: member, group: group, role: "member")
    event = create_event(group: group, owner: owner)
    ticket = create_ticket(event: event)
    item = TicketItem.create!(ticket: ticket, user: buyer, event: event, status: "succeeded", amount: 1000, ticket_type: "event")

    assert TicketItemPolicy.new(manager, item).refund?
    assert TicketItemPolicy.new(owner, item).refund?
    assert_not TicketItemPolicy.new(member, item).refund?
  end

  test "a member cannot nest a wechat ticket onto an event" do
    owner = create_user
    member = create_user
    group = create_group(owner: owner, can_publish_event: "everyone")
    create_membership(user: member, group: group, role: "member")

    assert_no_difference "Event.count" do
      post "/api/v1/events", params: {
        event: { title: "Paid", start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour, group_id: group.id },
        tickets: [ { title: "GA", ticket_type: "event", quantity: 10,
          payment_methods_attributes: [ { chain: "wechat", kind: "fiat", price: 100 } ] } ]
      }, headers: auth_headers(member)
    end
    assert_response :unprocessable_entity
    assert_equal "only a group manager or owner may set up a WeChat-paid ticket", json_response["error"]
  end

  test "wechat prepay uses the mini openid when the merchant app id is the miniprogram" do
    owner = create_user
    buyer = create_user(wechat_mini_openid: "mini-payer", wechat_openid: nil)
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    ticket = create_ticket(event: event)
    setting = create_wechat_pay_setting(app_id: "wx-mini-app")
    item = TicketItem.create!(
      ticket: ticket, user: buyer, event: event, status: "pending", amount: 1000,
      ticket_type: "event", payment_provider: "wechat", wechat_pay_setting_id: setting.id
    )
    seen = nil
    order = ->(_setting, _item, payer_openid:) { seen = payer_openid; "prepay-id" }

    with_env("WECHAT_PAY_ENABLED" => "true", "WECHAT_MINI_APPID" => "wx-mini-app") do
      WechatPayGateway.stub(:create_jsapi_order, order) do
        WechatPayGateway.stub(:pay_params, { "appId" => "wx-mini-app" }) do
          post "/api/v1/tickets/wechat_prepay", params: { ticket_item_id: item.id }, headers: auth_headers(buyer)
        end
      end
    end
    assert_response :success
    assert_equal "mini-payer", seen

    buyer.update!(wechat_mini_openid: "mini-payer", wechat_openid: nil)
    setting.update!(app_id: "wx-official")
    item.update!(status: "pending", provider_ref: nil)
    with_env("WECHAT_PAY_ENABLED" => "true", "WECHAT_MINI_APPID" => "wx-mini-app") do
      post "/api/v1/tickets/wechat_prepay", params: { ticket_item_id: item.id }, headers: auth_headers(buyer)
    end
    assert_response :unprocessable_entity
    assert_equal "OPENID_REQUIRED", json_response["code"]
  end

  test "the follow feed keeps followed recommendations and shared attendance" do
    reader = create_user
    author = create_user(data: { "share_activity" => true, "city" => "shanghai" })
    outsider = create_user(data: { "share_activity" => true })
    group = create_group(owner: reader)
    event = create_event(group: group, owner: reader, status: "published", city: "shanghai")
    other = create_event(group: group, owner: reader, status: "published", city: "beijing")
    create_comment(user: author, item: event, comment_type: "recommendation", content: "come along")
    create_comment(user: outsider, item: event, comment_type: "recommendation", content: "not followed")
    create_participant(event: event, user: author, status: "attending")
    create_participant(event: other, user: author, status: "attending")
    post "/api/v1/follows", params: { target_type: "User", target_id: author.id }, headers: auth_headers(reader)

    get "/api/v1/follows/feed", params: { city: "shanghai" }, headers: auth_headers(reader)
    assert_response :success
    types = json_response["data"].map { |row| row["type"] }
    assert_includes types, "recommendation"
    assert_includes types, "registration_rollup"
    assert_equal [ "come along" ], json_response["data"].select { |row| row["type"] == "recommendation" }.map { |row| row["text"] }
    rollup = json_response["data"].find { |row| row["type"] == "registration_rollup" }
    assert_equal event.id, rollup.dig("event", "id")
    assert_equal 1, rollup["count"]
  end

  test "suggestions stay in the requested city and skip blocked people" do
    reader = create_user
    nearby = create_user(data: { "city" => "shanghai", "visibility" => "PUBLIC" })
    create_user(data: { "city" => "beijing", "visibility" => "PUBLIC" })
    blocked = create_user(data: { "city" => "shanghai", "visibility" => "PUBLIC" })
    post "/api/v1/blocks", params: { target_user_id: blocked.id }, headers: auth_headers(reader)

    get "/api/v1/users/suggestions", params: { city: "shanghai" }, headers: auth_headers(reader)
    assert_response :success
    assert_equal [ nearby.id ], json_response["data"].map { |row| row["id"] }
  end

  test "a registration list returns the caller's participant and event" do
    owner = create_user
    guest = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", city: "shanghai")
    participant = create_participant(event: event, user: guest, status: "attending")

    get "/api/v1/registrations", headers: auth_headers(guest)
    assert_response :success
    assert_equal participant.id, json_response.dig("data", 0, "participant", "id")
    assert_equal event.id, json_response.dig("data", 0, "event", "id")

    get "/api/v1/registrations/#{participant.id}", headers: auth_headers(guest)
    assert_response :success
    assert_equal event.id, json_response.dig("event", "id")
  end

  test "a manager can invite an existing user by id" do
    owner = create_user
    guest = create_user
    group = create_group(owner: owner)

    post "/api/v1/groups/#{group.id}/group_invites",
      params: { role: "manager", receivers: [ guest.id ] },
      headers: auth_headers(owner)
    assert_response :success
    assert_equal "added", json_response.dig("results", 0, "result")
    assert_equal "manager", group.memberships.find_by(user: guest).role
  end

  private

  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
