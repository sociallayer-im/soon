require "test_helper"

# The whole WeChat Pay path in one go, through the real endpoints, with only
# the outbound calls to WeChat itself stubbed: organizer creates the ticket,
# buyer RSVPs, prepay places the order, the signed callback confirms it, the
# organizer refunds, and the refund callback settles.
#
# The per-piece tests cover the failure modes; this one exists because the
# pieces have to line up — the order id has to survive as out_trade_no, the
# currency has to stay CNY from payment method through order to refund, and
# the seat has to come back exactly once at the end.
class Api::V1::WechatPurchaseJourneyTest < ActionDispatch::IntegrationTest
  include FactoryHelpers

  setup do
    ENV["WECHAT_PAY_ENABLED"] = "true"
    @merchant = create_wechat_pay_setting
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @buyer = create_user(wechat_openid: "o_journey_#{SecureRandom.hex(4)}")
  end

  teardown { ENV.delete("WECHAT_PAY_ENABLED") }

  test "a WeChat ticket goes from creation to purchase to refund" do
    # --- the organizer creates a ¥1 ticket, choosing no merchant ------------
    post "/api/v1/events/#{@event.id}/tickets",
      params: { ticket: { title: "微信票", ticket_type: "event", quantity: 3,
                          payment_methods_attributes: [ { chain: "wechat", kind: "fiat", price: 100 } ] } },
      headers: auth_headers(@owner)
    assert_response :success

    ticket = Ticket.find(json_response["id"])
    method = ticket.payment_methods.sole
    assert_equal "cny", method.currency, "the rail's currency is filled in without being asked for"
    assert_equal @merchant.id, method.wechat_pay_setting_id, "and so is the one platform merchant"

    # --- the buyer reserves a seat -----------------------------------------
    assert_difference -> { ticket.reload.quantity }, -1 do
      post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
        params: { payment_method_id: method.id, chain: "wechat" }, headers: auth_headers(@buyer)
    end
    assert_response :success

    order = TicketItem.find(json_response["ticket_item"]["id"])
    assert_equal "pending", order.status
    assert_equal "wechat", order.payment_provider
    assert_equal "cny", order.currency
    assert_equal 100, order.amount
    assert_equal @merchant.id, order.wechat_pay_setting_id

    # --- prepay: the order id IS out_trade_no ------------------------------
    sent = nil
    WechatPayGateway.stub :request, ->(_m, _p, setting:, body: nil) { sent = body; { "prepay_id" => "pp_journey" } } do
      post "/api/v1/tickets/wechat_prepay",
        params: { ticket_item_id: order.id }, headers: auth_headers(@buyer)
    end
    assert_response :success
    assert_equal order.id, sent[:out_trade_no]
    assert_equal 100, sent[:amount][:total]
    assert_equal @buyer.wechat_openid, sent[:payer][:openid]

    # The signature the browser will hand to WeixinJSBridge has to verify
    # against the merchant's key, or WeChat answers with a signature error the
    # buyer sees as "支付失败" with no further detail.
    params = json_response["pay_params"]
    assert FactoryHelpers.rsa_key.public_key.verify(
      OpenSSL::Digest::SHA256.new, Base64.decode64(params["paySign"]),
      "#{params['appId']}\n#{params['timeStamp']}\n#{params['nonceStr']}\n#{params['package']}\n"
    )

    # --- WeChat calls back; the buyer becomes a ticket holder --------------
    perform_enqueued_jobs do
      post_callback(paid_notification(order))
    end
    assert_response :no_content

    assert_equal "succeeded", order.reload.status
    assert_equal "4200_journey", order.txhash
    assert_equal "attending", order.participant.reload.status
    assert_equal 2, ticket.reload.quantity, "the seat stays sold"

    # --- the organizer refunds --------------------------------------------
    WechatPayGateway.stub :request, ->(*, **) { { "refund_id" => "50000_journey", "status" => "PROCESSING" } } do
      post "/api/v1/tickets/#{order.id}/refund", headers: auth_headers(@owner)
    end
    assert_response :success

    refund = order.refunds.sole
    assert_equal "cny", refund.currency
    assert_equal 100, refund.amount
    # Still pending — a refund is asynchronous on this rail, so nothing has
    # been released yet.
    assert_equal "pending", refund.status
    assert_equal "succeeded", order.reload.status
    assert_equal 2, ticket.reload.quantity

    # --- and WeChat confirms it -------------------------------------------
    perform_enqueued_jobs do
      post_callback(refunded_notification(order, refund))
    end
    assert_response :no_content

    assert_equal "succeeded", refund.reload.status
    assert_equal "refunded", order.reload.status
    assert_equal 3, ticket.reload.quantity, "the seat comes back exactly once"
    assert_equal "cancelled", order.participant.reload.status
  end

  private

  def paid_notification(order)
    encrypted("TRANSACTION.SUCCESS", {
      "out_trade_no" => order.id, "transaction_id" => "4200_journey", "trade_state" => "SUCCESS",
      "mchid" => @merchant.mchid, "appid" => @merchant.app_id,
      "amount" => { "total" => order.amount, "currency" => "CNY" },
      "payer" => { "openid" => @buyer.wechat_openid }
    })
  end

  def refunded_notification(order, refund)
    encrypted("REFUND.SUCCESS", {
      "out_trade_no" => order.id, "out_refund_no" => refund.id, "refund_id" => "50000_journey",
      "refund_status" => "SUCCESS", "amount" => { "total" => order.amount, "refund" => refund.amount }
    }, associated_data: "refund")
  end

  def encrypted(event_type, resource, associated_data: "transaction")
    nonce = SecureRandom.alphanumeric(12)
    cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
    cipher.key = @merchant.apiv3_key
    cipher.iv = nonce
    cipher.auth_data = associated_data
    ciphertext = cipher.update(JSON.generate(resource)) + cipher.final

    { "id" => "EV-#{SecureRandom.hex(6)}", "event_type" => event_type,
      "resource" => { "algorithm" => "AEAD_AES_256_GCM", "associated_data" => associated_data,
                      "nonce" => nonce, "ciphertext" => Base64.strict_encode64(ciphertext + cipher.auth_tag) } }
  end

  def post_callback(envelope)
    body = JSON.generate(envelope)
    timestamp = Time.current.to_i.to_s
    nonce = "n#{SecureRandom.hex(4)}"
    signature = Base64.strict_encode64(
      FactoryHelpers.rsa_key.sign(OpenSSL::Digest::SHA256.new, "#{timestamp}\n#{nonce}\n#{body}\n")
    )

    post "/api/v1/webhooks/wechat/#{@merchant.id}", params: body, headers: {
      "CONTENT_TYPE" => "application/json",
      "Wechatpay-Timestamp" => timestamp, "Wechatpay-Nonce" => nonce,
      "Wechatpay-Signature" => signature, "Wechatpay-Serial" => @merchant.public_key_id
    }
  end
end
