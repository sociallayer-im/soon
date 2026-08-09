require "test_helper"

# The three cryptographic primitives are exercised for real here — the same
# keypair signs and verifies, the same APIv3 key encrypts and decrypts — so
# these tests fail on a wrong byte layout, which is the only way this code
# goes wrong. Only the HTTP call itself is stubbed.
class WechatPayGatewayTest < ActiveSupport::TestCase
  setup do
    @setting = create_wechat_pay_setting
    owner = create_user
    group = create_group(owner: owner)
    @event = create_event(group: group, owner: owner, title: "Sola Day")
    @ticket = create_ticket(event: @event, title: "GA")
    buyer = create_user
    @item = TicketItem.create!(ticket: @ticket, event: @event, user: buyer, ticket_type: "event",
      status: "pending", amount: 100, currency: "cny", payment_provider: "wechat",
      wechat_pay_setting_id: @setting.id)
  end

  # ---- request signing ----

  test "the Authorization header carries the merchant's serial and verifies against its key" do
    header = WechatPayGateway.authorization(@setting, :post, "/v3/pay/transactions/jsapi", '{"a":1}')

    assert_match(/\AWECHATPAY2-SHA256-RSA2048 /, header)
    fields = header.sub("WECHATPAY2-SHA256-RSA2048 ", "").scan(/(\w+)="([^"]*)"/).to_h
    assert_equal @setting.mchid, fields["mchid"]
    assert_equal @setting.cert_serial, fields["serial_no"]

    # The canonical string is method\nurl\ntimestamp\nnonce\nbody\n — a
    # signature that verifies against exactly that is the only proof the
    # layout is right, and WeChat's own error for getting it wrong
    # (SIGN_ERROR) says nothing about which part.
    message = "POST\n/v3/pay/transactions/jsapi\n#{fields['timestamp']}\n#{fields['nonce_str']}\n{\"a\":1}\n"
    assert FactoryHelpers.rsa_key.public_key.verify(
      OpenSSL::Digest::SHA256.new, Base64.decode64(fields["signature"]), message
    )
  end

  test "pay_params signs appId/timeStamp/nonceStr/package and nothing else" do
    params = WechatPayGateway.pay_params(@setting, "prepay_abc")

    assert_equal @setting.app_id, params[:appId]
    assert_equal "prepay_id=prepay_abc", params[:package]
    assert_equal "RSA", params[:signType]

    message = "#{params[:appId]}\n#{params[:timeStamp]}\n#{params[:nonceStr]}\n#{params[:package]}\n"
    assert FactoryHelpers.rsa_key.public_key.verify(
      OpenSSL::Digest::SHA256.new, Base64.decode64(params[:paySign]), message
    )
  end

  # ---- callback verification ----

  def signed_notification(body:, timestamp: Time.current.to_i.to_s, nonce: "abc123", key: FactoryHelpers.rsa_key)
    {
      timestamp: timestamp, nonce: nonce, body: body,
      signature: Base64.strict_encode64(key.sign(OpenSSL::Digest::SHA256.new, "#{timestamp}\n#{nonce}\n#{body}\n")),
      serial: @setting.public_key_id
    }
  end

  test "a correctly signed notification verifies" do
    assert WechatPayGateway.verify_notification(@setting, **signed_notification(body: '{"id":"1"}'))
  end

  test "a tampered body fails verification" do
    args = signed_notification(body: '{"id":"1"}')

    assert_not WechatPayGateway.verify_notification(@setting, **args.merge(body: '{"id":"2"}'))
  end

  test "a notification signed by some other key fails verification" do
    args = signed_notification(body: '{"id":"1"}', key: OpenSSL::PKey::RSA.generate(2048))

    assert_not WechatPayGateway.verify_notification(@setting, **args)
  end

  # The serial names which key signed the callback. Verifying a mismatched
  # serial against our key would be verifying nothing.
  test "a notification claiming a different key serial is refused" do
    args = signed_notification(body: '{"id":"1"}')

    assert_not WechatPayGateway.verify_notification(@setting, **args.merge(serial: "PUB_KEY_ID_SOMEONE_ELSE"))
  end

  # Without a window, a captured callback replays forever — and a replayed
  # REFUND.SUCCESS is not harmless.
  test "a signature older than the replay window is refused even though it is valid" do
    args = signed_notification(body: '{"id":"1"}', timestamp: 10.minutes.ago.to_i.to_s)

    assert_not WechatPayGateway.verify_notification(@setting, **args)
  end

  # This endpoint is open to the internet. Missing key must fail closed.
  test "a merchant with no public key verifies nothing" do
    @setting.update_column(:public_key, nil)

    assert_not WechatPayGateway.verify_notification(@setting, **signed_notification(body: '{"id":"1"}'))
  end

  # ---- resource decryption ----

  def encrypt_resource(plaintext, key: @setting.apiv3_key, aad: "transaction", nonce: SecureRandom.alphanumeric(12))
    cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
    cipher.key = key
    cipher.iv = nonce
    cipher.auth_data = aad
    ciphertext = cipher.update(plaintext) + cipher.final
    {
      "algorithm" => "AEAD_AES_256_GCM", "nonce" => nonce, "associated_data" => aad,
      "ciphertext" => Base64.strict_encode64(ciphertext + cipher.auth_tag)
    }
  end

  test "a resource encrypted with the APIv3 key round-trips" do
    resource = encrypt_resource('{"out_trade_no":"abc","trade_state":"SUCCESS"}')

    decrypted = WechatPayGateway.decrypt_resource(@setting, resource)
    assert_equal "abc", decrypted["out_trade_no"]
    assert_equal "SUCCESS", decrypted["trade_state"]
  end

  test "a resource encrypted under a different APIv3 key decrypts to nil, not garbage" do
    resource = encrypt_resource('{"out_trade_no":"abc"}', key: SecureRandom.alphanumeric(32))

    assert_nil WechatPayGateway.decrypt_resource(@setting, resource)
  end

  # associated_data is authenticated, not encrypted — changing it must fail the
  # tag rather than pass through.
  test "tampered associated_data fails the auth tag" do
    resource = encrypt_resource('{"out_trade_no":"abc"}').merge("associated_data" => "refund")

    assert_nil WechatPayGateway.decrypt_resource(@setting, resource)
  end

  # ---- order calls ----

  test "create_jsapi_order sends the amount in fen with the order id as out_trade_no" do
    sent = nil
    WechatPayGateway.stub :request, ->(_m, _p, setting:, body: nil) { sent = body; { "prepay_id" => "pp_1" } } do
      assert_equal "pp_1", WechatPayGateway.create_jsapi_order(@setting, @item, payer_openid: "o_buyer")
    end

    assert_equal @item.id, sent[:out_trade_no]
    assert_equal 100, sent[:amount][:total]
    assert_equal "CNY", sent[:amount][:currency]
    assert_equal "o_buyer", sent[:payer][:openid]
    assert_equal @setting.app_id, sent[:appid]
    assert_match "Sola Day", sent[:description]
    # A "Z" suffix is rejected as malformed; the offset has to be numeric.
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\z/, sent[:time_expire])
  end

  test "notify_url points at the backend origin, per merchant" do
    with_env("API_URL" => "https://api.juluo.xyz") do
      assert_equal "https://api.juluo.xyz/api/v1/webhooks/wechat/#{@setting.id}",
        WechatPayGateway.notify_url(@setting)
    end
  end

  # "We could not ask" and "it was not paid" are different facts, and only one
  # of them may expire an order.
  test "query_order returns nil when WeChat could not be reached" do
    WechatPayGateway.stub :request, ->(*, **) { raise WechatPayGateway::Error.new("timeout") } do
      assert_nil WechatPayGateway.query_order(@setting, @item.id)
    end
  end

  # The spelling here is not cosmetic and not guessable from the docs: a live
  # query answers ORDER_NOT_EXIST, the v2-era documentation says ORDERNOTEXIST.
  # Matching only one turns "unpaid" into "unreachable", which makes the sweeper
  # skip the order forever and never release the seat.
  test "query_order treats every order-missing code as a definite not-paid" do
    WechatPayGateway::ORDER_MISSING_CODES.each do |code|
      WechatPayGateway.stub :request, ->(*, **) { raise WechatPayGateway::Error.new("no order", code: code) } do
        result = WechatPayGateway.query_order(@setting, @item.id)
        assert_equal "NOTPAY", result["trade_state"], "#{code} must read as not-paid, not as unreachable"
      end
    end
    assert_includes WechatPayGateway::ORDER_MISSING_CODES, "ORDER_NOT_EXIST",
      "this is what the live API actually returns — verified 2026-08-08"
  end

  # An unpaid order must reach item.timeout, and it only does so if the
  # not-exist code is recognised. This is the sweeper-level consequence of the
  # test above, which is where the bug would actually have bitten.
  test "the sweeper expires an order WeChat says was never placed" do
    @item.update!(reserved_until: 5.minutes.ago)

    WechatPayGateway.stub :request, ->(*, **) { raise WechatPayGateway::Error.new("订单不存在", code: "ORDER_NOT_EXIST") } do
      WechatPayGateway.stub :close_order, true do
        TicketingSweeperJob.perform_now
      end
    end

    assert_equal "timeout", @item.reload.status
  end

  # The refund endpoint answered with a body Net::HTTP could not inflate,
  # raising Zlib::DataError AFTER the refund had already been accepted — a 500
  # for an operation that succeeded. The request now asks for identity so
  # there is nothing to decode, and any remaining read failure is Unreachable
  # rather than Error, because "we could not read the answer" and "it was
  # refused" must not be handled the same way.
  # httpx reports transport trouble as a response object rather than by
  # raising. Everything it covers means the request may have been carried out
  # and we cannot say — which is not a rejection and must not be reported as
  # one, because the caller records a rejection as `failed` and invites a retry.
  test "a response we cannot read is Unreachable, not a refusal" do
    [ Zlib::DataError.new("incorrect header check"), Errno::ECONNRESET.new, EOFError.new ].each do |boom|
      error = assert_raises(WechatPayGateway::Unreachable) do
        WechatPayGateway.handle_response(error_response(boom))
      end
      assert_match "could not read", error.message
    end
  end

  test "Unreachable is still an Error, so query_order keeps reading it as cannot-ask" do
    assert_operator WechatPayGateway::Unreachable, :<, WechatPayGateway::Error

    WechatPayGateway.stub :request, ->(*, **) { raise WechatPayGateway::Unreachable, "boom" } do
      assert_nil WechatPayGateway.query_order(@setting, @item.id)
    end
  end

  # The gzip default is what produced a 500 for a refund that had already been
  # accepted, so the request states its encoding rather than trusting a
  # library default to stay put.
  test "the request asks for identity encoding and signs the exact body sent" do
    seen = nil
    # Captured outside the block: inside define_singleton_method, self is the
    # session double rather than the test case.
    boom = error_response(Errno::ECONNRESET.new)
    session = Object.new
    session.define_singleton_method(:request) do |verb, url, **opts|
      seen = { verb: verb, url: url, body: opts[:body] }
      boom
    end

    captured_options = nil
    HTTPX.stub :with, ->(**opts) { captured_options = opts; session } do
      assert_raises(WechatPayGateway::Unreachable) do
        WechatPayGateway.request(:post, "/v3/pay/transactions/jsapi", setting: @setting, body: { a: 1 })
      end
    end

    assert_equal "identity", captured_options[:headers]["Accept-Encoding"]
    assert_equal "POST", seen[:verb]
    assert_equal "https://api.mch.weixin.qq.com/v3/pay/transactions/jsapi", seen[:url]
    # The signature covers the byte-for-byte body; sending a differently
    # serialized one is SIGN_ERROR, with no hint which half was wrong.
    assert_equal '{"a":1}', seen[:body]
  end

  test "a non-2xx answer is a refusal, carrying WeChat's own code" do
    response = Struct.new(:status, :body).new(403, '{"code":"NOTENOUGH","message":"余额不足"}')

    error = assert_raises(WechatPayGateway::Error) { WechatPayGateway.handle_response(response) }
    assert_equal "NOTENOUGH", error.code
    assert_equal 403, error.status
    assert_not_kind_of WechatPayGateway::Unreachable, error, "a refusal is not an unknown outcome"
  end

  test "close_order reports failure instead of raising into the sweeper" do
    WechatPayGateway.stub :request, ->(*, **) { raise WechatPayGateway::Error.new("already closed") } do
      assert_not WechatPayGateway.close_order(@setting, @item.id)
    end
  end

  test "服务商 mode refuses rather than guessing at the partner endpoints" do
    partner = create_wechat_pay_setting(sub_mchid: "1900000109")

    assert_raises(WechatPayGateway::UnsupportedMode) do
      WechatPayGateway.create_jsapi_order(partner, @item, payer_openid: "o_buyer")
    end
  end

  private

  # httpx's ErrorResponse takes a real request — it reads options and the
  # response off it — so a bare double will not do.
  def error_response(error)
    request = HTTPX::Request.new("POST", "https://#{WechatPayGateway::API_HOST}/v3/probe", HTTPX::Options.new)
    HTTPX::ErrorResponse.new(request, error)
  end

  def with_env(vars)
    previous = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
