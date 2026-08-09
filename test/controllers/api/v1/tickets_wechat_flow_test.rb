require "test_helper"

# wechat_prepay + the callback receiver + refund dispatch, the WeChat
# counterpart of tickets_stripe_flow_test.
class Api::V1::TicketsWechatFlowTest < ActionDispatch::IntegrationTest
  include FactoryHelpers

  setup do
    ENV["WECHAT_PAY_ENABLED"] = "true"
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @ticket = create_ticket(event: @event, quantity: 5)
    @merchant = create_wechat_pay_setting
    @buyer = create_user(wechat_openid: "o_buyer_#{SecureRandom.hex(4)}")
  end

  teardown { ENV.delete("WECHAT_PAY_ENABLED") }

  def create_order(status: "pending", **attrs)
    TicketItem.create!({ ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: status, amount: 100, currency: "cny", payment_provider: "wechat",
      wechat_pay_setting_id: @merchant.id }.merge(attrs))
  end

  # ---------------------------------------------------------------- prepay

  test "wechat_prepay places the order and returns signed bridge parameters" do
    item = create_order(reserved_until: 5.minutes.from_now)

    WechatPayGateway.stub :create_jsapi_order, "prepay_xyz" do
      post "/api/v1/tickets/wechat_prepay",
        params: { ticket_item_id: item.id }, headers: auth_headers(@buyer)
    end
    assert_response :success

    params = json_response["pay_params"]
    assert_equal "prepay_id=prepay_xyz", params["package"]
    assert_equal "RSA", params["signType"]
    assert params["paySign"].present?
    assert_equal "prepay_xyz", item.reload.provider_ref
    assert item.reserved_until > 20.minutes.from_now, "the seat must outlive WeChat's own order expiry"
  end

  # A buyer who signed in by email has no openid, and JSAPI cannot place an
  # order without one. The distinct code is what lets the frontend recover with
  # a silent authorize instead of showing a dead end.
  test "a buyer with no openid gets OPENID_REQUIRED rather than a generic failure" do
    emailer = create_user
    item = create_order(user: emailer)

    post "/api/v1/tickets/wechat_prepay",
      params: { ticket_item_id: item.id }, headers: auth_headers(emailer)

    assert_response :unprocessable_entity
    assert_equal "OPENID_REQUIRED", json_response["code"]
  end

  test "wechat_prepay is owner-only and pending-only" do
    item = create_order
    post "/api/v1/tickets/wechat_prepay",
      params: { ticket_item_id: item.id }, headers: auth_headers(create_user)
    assert_response :forbidden

    settled = create_order(status: "succeeded")
    post "/api/v1/tickets/wechat_prepay",
      params: { ticket_item_id: settled.id }, headers: auth_headers(@buyer)
    assert_response :unprocessable_entity
  end

  test "wechat_prepay refuses a stripe order" do
    item = create_order(payment_provider: "stripe", wechat_pay_setting_id: nil)

    post "/api/v1/tickets/wechat_prepay",
      params: { ticket_item_id: item.id }, headers: auth_headers(@buyer)
    assert_response :unprocessable_entity
    assert_match "not for wechat", json_response["error"]
  end

  test "wechat_prepay 404s when WECHAT_PAY_ENABLED is unset (SG)" do
    ENV.delete("WECHAT_PAY_ENABLED")
    item = create_order

    post "/api/v1/tickets/wechat_prepay",
      params: { ticket_item_id: item.id }, headers: auth_headers(@buyer)
    assert_response :not_found
  end

  # ---------------------------------------------------------------- callbacks

  def post_callback(envelope, setting: @merchant, key: FactoryHelpers.rsa_key, timestamp: Time.current.to_i.to_s)
    body = JSON.generate(envelope)
    nonce = "nonce123"
    signature = Base64.strict_encode64(key.sign(OpenSSL::Digest::SHA256.new, "#{timestamp}\n#{nonce}\n#{body}\n"))

    post "/api/v1/webhooks/wechat/#{setting.id}", params: body, headers: {
      "CONTENT_TYPE" => "application/json",
      "Wechatpay-Timestamp" => timestamp, "Wechatpay-Nonce" => nonce,
      "Wechatpay-Signature" => signature, "Wechatpay-Serial" => setting.public_key_id
    }
  end

  def encrypted_envelope(plaintext, id: "EV-#{SecureRandom.hex(6)}", event_type: "TRANSACTION.SUCCESS", setting: @merchant)
    nonce = SecureRandom.alphanumeric(12)
    cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
    cipher.key = setting.apiv3_key
    cipher.iv = nonce
    cipher.auth_data = "transaction"
    ciphertext = cipher.update(JSON.generate(plaintext)) + cipher.final

    { "id" => id, "event_type" => event_type, "resource_type" => "encrypt-resource",
      "resource" => { "algorithm" => "AEAD_AES_256_GCM", "original_type" => "transaction",
                      "associated_data" => "transaction", "nonce" => nonce,
                      "ciphertext" => Base64.strict_encode64(ciphertext + cipher.auth_tag) } }
  end

  test "a signed callback is stored with its resource decrypted and enqueued" do
    item = create_order
    envelope = encrypted_envelope({ "out_trade_no" => item.id, "trade_state" => "SUCCESS", "transaction_id" => "4200009" })

    assert_enqueued_with(job: WechatPayWebhookJob) do
      post_callback(envelope)
    end
    assert_response :no_content

    record = WechatPayEvent.find(envelope["id"])
    assert_equal "TRANSACTION.SUCCESS", record.event_type
    # Stored decrypted: the job holds no key, and keeping the ciphertext too
    # would store the same data twice, once unreadably.
    assert_equal item.id, record.resource["out_trade_no"]
    assert_nil record.payload["resource"]["ciphertext"]
  end

  test "an unsigned or wrongly signed callback is refused and stores nothing" do
    envelope = encrypted_envelope({ "out_trade_no" => "x" })

    assert_no_difference "WechatPayEvent.count" do
      post_callback(envelope, key: OpenSSL::PKey::RSA.generate(2048))
    end
    assert_response :unauthorized
    assert_equal "FAIL", json_response["code"]
  end

  # WeChat retries for 24 hours; the second delivery must be acknowledged so
  # it stops, without processing anything twice.
  test "a duplicate delivery is acknowledged once and stored once" do
    item = create_order
    envelope = encrypted_envelope({ "out_trade_no" => item.id, "trade_state" => "SUCCESS" })

    post_callback(envelope)
    assert_response :no_content

    assert_no_difference "WechatPayEvent.count" do
      post_callback(envelope)
    end
    assert_response :no_content
  end

  # A verified envelope we cannot decrypt means our APIv3 key is wrong. FAIL
  # keeps WeChat retrying; a 200 would throw the notification away.
  test "an undecryptable resource answers FAIL so the retry survives the fix" do
    envelope = encrypted_envelope({ "out_trade_no" => "x" }, setting: create_wechat_pay_setting)

    post_callback(envelope)
    assert_response :bad_request
    assert_equal "FAIL", json_response["code"]
  end

  test "the callback endpoint 404s when WeChat Pay is not enabled on this deployment" do
    ENV.delete("WECHAT_PAY_ENABLED")
    post_callback(encrypted_envelope({ "out_trade_no" => "x" }))
    assert_response :not_found
  end

  # ---------------------------------------------------------------- refund

  test "the organizer refunds a wechat order through the snapshotted merchant" do
    item = create_order(status: "succeeded", txhash: "4200001")
    seen = nil

    WechatPayGateway.stub :create_refund, ->(setting, _i, r) { seen = [ setting.id, r.amount ]; { "refund_id" => "50000_a" } } do
      post "/api/v1/tickets/#{item.id}/refund", headers: auth_headers(@owner)
    end
    assert_response :success

    refund = item.refunds.sole
    assert_equal [ @merchant.id, 100 ], seen
    assert_equal "50000_a", refund.provider_ref
    assert_equal "cny", refund.currency
    # Still pending: only the REFUND.SUCCESS callback settles it.
    assert_equal "pending", refund.status
    assert_equal "succeeded", item.reload.status
  end

  # The 500 seen in production: the refund was accepted by WeChat and only the
  # response could not be read. Answering "failed" would be a lie in the
  # dangerous direction — the organizer clicks again and a partial refund goes
  # out twice (the unique index only catches a duplicate FULL refund).
  test "an unreadable response leaves the refund pending, never failed" do
    item = create_order(status: "succeeded", txhash: "4200001")

    WechatPayGateway.stub :create_refund, ->(*) { raise WechatPayGateway::Unreachable, "could not read WeChat Pay's response: Zlib::DataError" } do
      post "/api/v1/tickets/#{item.id}/refund", headers: auth_headers(@owner)
    end

    assert_response :success
    assert json_response["awaiting_confirmation"]

    refund = item.refunds.sole
    assert_equal "pending", refund.status, "a sent refund must not be recorded as failed"
    assert_nil refund.error
    # And the callback still settles it, because out_refund_no is the row id.
    assert_equal "succeeded", item.reload.status

    perform_enqueued_jobs do
      post_callback(encrypted_envelope({
        "out_trade_no" => item.id, "out_refund_no" => refund.id, "refund_id" => "50000_late",
        "refund_status" => "SUCCESS", "amount" => { "total" => 100, "refund" => 100 }
      }, event_type: "REFUND.SUCCESS"))
    end

    assert_equal "succeeded", refund.reload.status
    assert_equal "refunded", item.reload.status
  end

  # A refusal is different: nothing moved, so recording it failed is correct
  # and frees the index for a retry.
  test "a refusal from WeChat is recorded as failed" do
    item = create_order(status: "succeeded", txhash: "4200001")

    WechatPayGateway.stub :create_refund, ->(*) { raise WechatPayGateway::Error.new("余额不足", code: "NOTENOUGH", status: 403) } do
      post "/api/v1/tickets/#{item.id}/refund", headers: auth_headers(@owner)
    end

    assert_response :unprocessable_entity
    assert_equal "failed", item.refunds.sole.status
    assert_includes item.ticketing_activities.map(&:action), "refund_failed"
  end

  test "a wechat refund is refused to someone who does not manage the event" do
    item = create_order(status: "succeeded", txhash: "4200001")

    post "/api/v1/tickets/#{item.id}/refund", headers: auth_headers(create_user)
    assert_response :forbidden
  end

  # ---------------------------------------------------------------- order list

  # What the organizer's Orders tab renders. Without the refunds and the
  # timestamps there is nothing to show a history from — the order model keeps
  # only a current status.
  test "the manager order list carries refunds and the timestamps a history needs" do
    item = create_order(status: "succeeded", txhash: "4200001", paid_at: 2.hours.ago)
    refund = item.refunds.create!(requested_by: @owner, amount: 40, currency: "cny",
      full_refund: false, reason: "partial")

    get "/api/v1/tickets/list", params: { event_id: @event.id }, headers: auth_headers(@owner)
    assert_response :success

    row = json_response.sole
    assert_equal item.id, row["id"]
    assert_equal "wechat", row["payment_provider"]
    assert_not_nil row["paid_at"]
    assert_equal @ticket.title, row.dig("ticket", "title")

    assert_equal 1, row["refunds"].length
    assert_equal refund.id, row["refunds"][0]["id"]
    assert_equal 40, row["refunds"][0]["amount"]
    # Pending, not succeeded — a refund is asynchronous, and hiding it until
    # settled would blank it out during exactly the window someone is
    # watching for it.
    assert_equal "pending", row["refunds"][0]["status"]
    assert_equal false, row["refunds"][0]["full_refund"]
    # Who ordered it, by name — an audit trail nobody can read is not one.
    assert_equal @owner.name, row["refunds"][0].dig("requested_by", "name")
    assert_nil row["refunds"][0].dig("requested_by", "email"), "the actor's email is not the organizer's business"
  end

  # Accountability: a refund is the one organizer action that moves money out,
  # so the manager who ordered it is named — and the steps a person did NOT
  # take are just as clearly unattributed.
  test "the timeline names the manager who refunded, and nobody for the callback" do
    item = create_order(status: "succeeded", txhash: "4200001")
    # A co-host, not a group manager: refund rights are deliberately narrower
    # than edit rights (PAYMENTS_PLAN decision #6), so the actor has to be
    # someone the policy actually allows.
    cohost = create_user
    create_event_role(event: @event, item: cohost, role: "co_host")

    WechatPayGateway.stub :create_refund, ->(*) { { "refund_id" => "50000_who" } } do
      post "/api/v1/tickets/#{item.id}/refund", headers: auth_headers(cohost)
    end
    assert_response :success

    perform_enqueued_jobs do
      post_callback(encrypted_envelope({
        "out_trade_no" => item.id, "out_refund_no" => item.refunds.sole.id,
        "refund_id" => "50000_who", "refund_status" => "SUCCESS",
        "amount" => { "total" => 100, "refund" => 100 }
      }, event_type: "REFUND.SUCCESS"))
    end

    get "/api/v1/tickets/list", params: { event_id: @event.id }, headers: auth_headers(@owner)
    activities = json_response.sole["activities"].index_by { |a| a["action"] }

    assert_equal cohost.name, activities["refund_requested"].dig("actor", "name")
    assert_equal "api", activities["refund_requested"]["source"]
    # WeChat settled it, not a person. The absent actor is the record of that.
    assert_nil activities["refund_succeeded"]["actor"]
    assert_equal "webhook", activities["refund_succeeded"]["source"]
  end

  test "a buyer sees their own orders without the organizer-facing refund detail" do
    create_order(status: "succeeded", txhash: "4200001")

    get "/api/v1/tickets/list",
      params: { event_id: @event.id, profile_handle: @buyer.name }, headers: auth_headers(@buyer)
    assert_response :success
    assert_nil json_response.sole["refunds"]
  end

  test "the whole-event order list stays manager-only" do
    create_order(status: "succeeded")

    get "/api/v1/tickets/list", params: { event_id: @event.id }, headers: auth_headers(create_user)
    assert_response :forbidden
  end

  # ---------------------------------------------------------------- set_payment_status

  # This endpoint is authenticated by a shared secret and does no payment
  # verification. Leaving a fiat rail open on it hands anyone holding
  # NEXT_TOKEN the ability to mint paid tickets.
  test "set_payment_status refuses to confirm a wechat order" do
    ENV["NEXT_TOKEN"] = "test-token"
    item = create_order(chain: "wechat")

    post "/api/v1/tickets/set_payment_status",
      params: { next_token: "test-token", product_id: @event.id, item_id: item.id, amount: 100, chain: "wechat" }
    assert_response :forbidden
    assert_match "confirmed via webhook only", json_response["error"]
    assert_equal "pending", item.reload.status
  ensure
    ENV.delete("NEXT_TOKEN")
  end
end
