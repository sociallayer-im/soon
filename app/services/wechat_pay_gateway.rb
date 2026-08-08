# All WeChat Pay APIv3 access goes through here, structurally the counterpart
# of StripeGateway: every method takes the WechatPaySetting whose merchant it
# acts on, and nothing reads credentials from the environment at call time
# (design/WECHAT_INTEGRATION.md §2.3–2.4).
#
# Written directly against OpenSSL and httpx rather than through a WeChat gem.
# The whole protocol is three primitives — sign an outgoing request, verify an
# incoming signature, AES-GCM-decrypt a callback resource — and each is a
# handful of lines whose exact byte layout has to be right; a dependency here
# would hide that without removing it.
class WechatPayGateway
  API_HOST = "api.mch.weixin.qq.com".freeze

  # WeChat rejects requests without a User-Agent outright.
  USER_AGENT = "soon/1.0 (+https://api.juluo.xyz)".freeze

  # The prepay_id is good for 2 hours, but the order should not outlive the
  # seat it is holding. Kept just under the reservation so the sweeper is
  # always the thing that expires an order, never a surprise from WeChat.
  ORDER_TTL = 30.minutes

  # One thread of GoodJob serves webhooks, the sweeper and mail. A slow
  # merchant API call must not become a stalled queue.
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  class Error < StandardError
    attr_reader :code, :status

    def initialize(message, code: nil, status: nil)
      super(message)
      @code = code
      @status = status
    end
  end

  # The request went out but its outcome could not be read — a timeout, a
  # reset, a body we could not decode.
  #
  # Deliberately NOT the same thing as an Error, which means WeChat answered
  # and said no. The two demand opposite responses: a rejection is safe to
  # record as failed, an unreadable answer is not. Recording "failed" for a
  # refund that actually went through invites the organizer to click again,
  # and the second one refunds the buyer twice.
  class Unreachable < Error; end

  # 服务商 mode uses a different endpoint family (/v3/pay/partner/…) and
  # different field names (sp_appid/sp_mchid/sub_mchid). Nothing here has ever
  # run against it, so it refuses loudly rather than sending a request whose
  # shape is a guess.
  class UnsupportedMode < Error; end

  # ---- outbound calls ----

  # JSAPI order. Returns the prepay_id; the browser then needs #pay_params to
  # actually invoke the WeChat payment sheet.
  #
  # `payer_openid` must have been issued by THIS merchant's bound appid —
  # openid is per-appid, and one from anywhere else is rejected by WeChat with
  # a message that does not say so.
  def self.create_jsapi_order(setting, ticket_item, payer_openid:)
    reject_partner_mode!(setting)

    event = ticket_item.event
    body = {
      appid: setting.app_id,
      mchid: setting.mchid,
      description: description_for(event, ticket_item),
      out_trade_no: ticket_item.id,
      notify_url: notify_url(setting),
      amount: { total: ticket_item.amount.to_i, currency: (ticket_item.currency || setting.currency).upcase },
      payer: { openid: payer_openid },
      time_expire: rfc3339(ORDER_TTL.from_now)
    }

    request(:post, "/v3/pay/transactions/jsapi", setting: setting, body: body).fetch("prepay_id")
  end

  # The parameters WeixinJSBridge.invoke('getBrandWCPayRequest', …) needs.
  # paySign is computed here and only here: it needs the merchant private key,
  # so a browser could not produce it — which is the entire reason the
  # bridge's own success callback is untrustworthy and never marks an order
  # paid (§2.4 ②).
  def self.pay_params(setting, prepay_id)
    timestamp = Time.current.to_i.to_s
    nonce = SecureRandom.hex(16)
    package = "prepay_id=#{prepay_id}"
    signature = sign(setting, "#{setting.app_id}\n#{timestamp}\n#{nonce}\n#{package}\n")

    {
      appId: setting.app_id, timeStamp: timestamp, nonceStr: nonce,
      package: package, signType: "RSA", paySign: signature
    }
  end

  # "This order was never placed" — a definite answer, not a failure.
  #
  # Both spellings are accepted because the documentation and the wire disagree:
  # a live query against api.mch.weixin.qq.com answers ORDER_NOT_EXIST, while
  # ORDERNOTEXIST appears in the v2-era docs. Matching only the documented one
  # meant every unpaid order looked unreachable instead of unpaid, so the
  # sweeper skipped it forever and the seat was never released.
  ORDER_MISSING_CODES = %w[ORDER_NOT_EXIST ORDERNOTEXIST].freeze

  # The authoritative answer on whether an order was paid. Callbacks are an
  # optimization; this is what the sweeper and the confirm path trust.
  # Returns nil when WeChat could not be asked — which is NOT the same as
  # "not paid" and must never be treated as evidence of non-payment.
  def self.query_order(setting, out_trade_no)
    reject_partner_mode!(setting)

    request(:get, "/v3/pay/transactions/out-trade-no/#{out_trade_no}?mchid=#{setting.mchid}", setting: setting)
  rescue Error => e
    # No order was ever placed, so nothing was paid. Anything else (network,
    # 5xx, auth) is an absence of information rather than an answer.
    return { "trade_state" => "NOTPAY", "out_trade_no" => out_trade_no } if ORDER_MISSING_CODES.include?(e.code)

    Rails.logger.warn("[wechat_pay] query_order #{out_trade_no} failed: #{e.message}")
    nil
  end

  # Closing matters more here than on Stripe, where a Checkout Session expires
  # by itself. A WeChat order left open stays payable after we have released
  # the seat, which is how you end up holding money for a ticket that no
  # longer exists (§2.4 ⑤).
  def self.close_order(setting, out_trade_no)
    reject_partner_mode!(setting)

    request(:post, "/v3/pay/transactions/out-trade-no/#{out_trade_no}/close",
      setting: setting, body: { mchid: setting.mchid })
    true
  rescue Error => e
    # Already closed, already paid, or never placed — all fine to ignore; the
    # caller is releasing inventory either way and the order's own state is
    # decided by query_order, not by this.
    Rails.logger.info("[wechat_pay] close_order #{out_trade_no}: #{e.message}")
    false
  end

  # Refunds are asynchronous: a 200 here means accepted, not settled. The
  # REFUND.SUCCESS callback (or reconciliation) is what finalizes it — the
  # same shape as the Stripe path, so Refund/apply_refund_success! are reused
  # unchanged.
  def self.create_refund(setting, ticket_item, refund)
    reject_partner_mode!(setting)

    body = {
      transaction_id: ticket_item.txhash,
      out_refund_no: refund.id,
      notify_url: notify_url(setting),
      amount: {
        refund: refund.amount.to_i,
        total: ticket_item.amount.to_i,
        currency: (ticket_item.currency || setting.currency).upcase
      }
    }
    body[:reason] = refund.reason if refund.reason.present?

    request(:post, "/v3/refund/domestic/refunds", setting: setting, body: body)
  end

  # ---- callbacks ----

  # Verifies a callback's signature against the merchant's WeChat Pay public
  # key. Unlike an API response — reachable only by someone who has already
  # broken TLS — this endpoint is open to the internet, so a missing key is a
  # refusal, never a skip.
  def self.verify_notification(setting, timestamp:, nonce:, body:, signature:, serial:)
    key = setting.notify_public_key
    return false if key.nil?
    # The serial names which key signed it. Accepting a mismatch would mean
    # verifying against a key WeChat did not use, i.e. verifying nothing.
    return false if setting.public_key_id.present? && serial.present? && serial != setting.public_key_id
    # Replay window. WeChat's own guidance is 5 minutes; a signature stays
    # valid forever without it, so a captured callback could be replayed to
    # re-run whatever it triggers.
    return false if (Time.current.to_i - timestamp.to_i).abs > 300

    key.verify(OpenSSL::Digest::SHA256.new, Base64.decode64(signature.to_s),
      "#{timestamp}\n#{nonce}\n#{body}\n")
  rescue OpenSSL::PKey::PKeyError, ArgumentError
    false
  end

  # AES-256-GCM over the APIv3 key. The auth tag is the last 16 bytes of the
  # ciphertext, and associated_data is authenticated but not encrypted —
  # getting either wrong fails the tag check rather than yielding garbage,
  # which is the desired behaviour.
  def self.decrypt_resource(setting, resource)
    raw = Base64.decode64(resource["ciphertext"].to_s)
    return nil if raw.bytesize <= 16

    cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
    cipher.key = setting.apiv3_key
    cipher.iv = resource["nonce"].to_s
    cipher.auth_tag = raw[-16..]
    cipher.auth_data = resource["associated_data"].to_s
    JSON.parse(cipher.update(raw[0..-17]) + cipher.final)
  rescue OpenSSL::Cipher::CipherError, JSON::ParserError => e
    Rails.logger.warn("[wechat_pay] resource decrypt failed: #{e.class}")
    nil
  end

  # ---- urls ----

  # API_URL is the backend's own public origin (api.juluo.xyz). WEB_URL is the
  # frontend and would 404 the callback — and unset, this silently becomes
  # localhost, which WeChat cannot reach and never reports as a problem.
  def self.notify_url(setting)
    "#{ENV.fetch('API_URL', 'http://localhost:3000')}/api/v1/webhooks/wechat/#{setting.id}"
  end

  # ---- internals ----

  def self.description_for(event, ticket_item)
    # WeChat truncates at 127 characters and shows this on the payment sheet
    # and the bill.
    [ event&.title, ticket_item.ticket&.title ].compact.join(" - ").presence&.slice(0, 120) || "Ticket"
  end

  def self.rfc3339(time)
    # Must carry a numeric offset; a trailing "Z" is rejected as malformed.
    time.in_time_zone("Asia/Shanghai").strftime("%Y-%m-%dT%H:%M:%S%:z")
  end

  def self.sign(setting, message)
    Base64.strict_encode64(setting.rsa_private_key.sign(OpenSSL::Digest::SHA256.new, message))
  end

  def self.authorization(setting, method, path_with_query, body)
    timestamp = Time.current.to_i.to_s
    nonce = SecureRandom.hex(16)
    signature = sign(setting, "#{method.to_s.upcase}\n#{path_with_query}\n#{timestamp}\n#{nonce}\n#{body}\n")

    "WECHATPAY2-SHA256-RSA2048 " \
      "mchid=\"#{setting.mchid}\",nonce_str=\"#{nonce}\",signature=\"#{signature}\"," \
      "timestamp=\"#{timestamp}\",serial_no=\"#{setting.cert_serial}\""
  end

  def self.reject_partner_mode!(setting)
    return unless setting.service_provider?

    raise UnsupportedMode, "服务商 mode is not implemented: it needs the /v3/pay/partner/… endpoints " \
                           "and sp_appid/sp_mchid/sub_mchid fields, which have never been exercised here"
  end

  # httpx rather than Net::HTTP, for two defaults that bit this integration:
  #
  #   - Net::HTTP asks for gzip and inflates the reply unless the caller set
  #     accept-encoding IN THE CONSTRUCTOR (setting it afterwards is too late,
  #     which is not discoverable). The refund endpoint answered with something
  #     it could not inflate, raising Zlib::DataError *after* WeChat had
  #     accepted the refund — a 500 for an operation that succeeded.
  #   - Net::HTTP.start defaults its proxy argument to :ENV, so http_proxy
  #     silently reroutes payment traffic. This machine has one set.
  #
  # Accept-Encoding: identity is still sent explicitly. It costs nothing and
  # states the intent rather than relying on a library's defaults staying put.
  def self.request(method, path_with_query, setting:, body: nil)
    payload = body ? JSON.generate(body) : ""

    headers = {
      "Authorization" => authorization(setting, method, path_with_query, payload),
      "Accept" => "application/json",
      "Accept-Encoding" => "identity",
      "User-Agent" => USER_AGENT
    }
    headers["Content-Type"] = "application/json" if body

    response = HTTPX
      .with(headers: headers, timeout: { connect_timeout: OPEN_TIMEOUT, request_timeout: READ_TIMEOUT })
      .request(method.to_s.upcase, "https://#{API_HOST}#{path_with_query}", body: body ? payload : nil)

    handle_response(response)
  end

  def self.handle_response(response)
    # httpx returns an error object instead of raising. Everything it covers —
    # connect failures, timeouts, TLS, a truncated body — means the request may
    # have been carried out and we simply cannot say. That is not a rejection,
    # so it must not be reported as one.
    if response.is_a?(HTTPX::ErrorResponse)
      raise Unreachable, "could not read WeChat Pay's response: #{response.error.class}"
    end

    code = response.status
    raw = response.body.to_s
    parsed = raw.presence ? (JSON.parse(raw) rescue {}) : {}

    return parsed if code.between?(200, 299)

    raise Error.new(parsed["message"].presence || "WeChat Pay returned #{code}",
      code: parsed["code"], status: code)
  end
end
