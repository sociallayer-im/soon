# Aliyun 短信服务 (Dysmsapi), the one SMS rail — CN only.
#
# Lifted from semi-backend's lib/send_sms.rb (`send_sms_aliyun`), which is the
# implementation actually sending mail-order codes in production today; the
# credentials, 签名 and 模板 are the same Aliyun account, deliberately shared
# across both projects. That file also carried a Tencent Cloud path, dead code
# there (nothing calls it) and not carried over.
#
# Written against Aliyun's older RPC signing (HMAC-SHA1 over sorted, twice-
# encoded query params) rather than the v3 ROA style, because that is what the
# working implementation uses and the signature layout is the part most easily
# got wrong.
class SmsSender
  ENDPOINT = "https://dysmsapi.aliyuncs.com/".freeze
  API_VERSION = "2017-05-25".freeze

  # A user is staring at a spinner while this runs — request_phone_code sends
  # synchronously so a delivery failure surfaces on the request that asked for
  # it. Bound it tightly rather than hold a Puma thread (there are 3) on a
  # hung socket.
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # The 签名, deliberately NOT read from the environment like everything else
  # here.
  #
  # ginger's secret injection cannot carry a non-ASCII value: it reads
  # .env.cn.production's UTF-8 bytes as latin-1 and re-encodes them, so
  # "深圳市岑赫科技" arrives in the container double-encoded and every send comes
  # back isv.SMS_SIGNATURE_ILLEGAL — 该账号下找不到对应签名 (verified against CN
  # production 2026-08-11, where the identical probe locally answered
  # MOBILE_NUMBER_ILLEGAL). The 签名 is public, not a credential, so the safe
  # place for it is the source; semi-backend hardcodes it for the same reason.
  #
  # Changing it means changing this constant. Adding ALIYUN_SMS_SIGN_NAME back
  # to ginger.cn.yml's inject list will silently reintroduce the bug.
  SIGN_NAME = "深圳市岑赫科技".freeze

  class Error < StandardError; end
  # Configuration is missing — distinct from Aliyun answering "no", because
  # this one is our fault and is never fixed by retrying.
  class NotConfigured < Error; end

  class << self
    # Sends the login code. `phone` is E.164 (+86…); Aliyun's PhoneNumbers wants
    # it without the leading "+" for domestic numbers, and tolerates the 86
    # prefix, so the "+" is simply stripped.
    def send_login_code(phone:, code:)
      unless configured?
        # Dev and test have no Aliyun account. Log the code so the flow is
        # walkable locally; in production a missing key is a real outage and
        # must not degrade into "codes nobody receives".
        raise NotConfigured, "Aliyun SMS credentials are not configured" if Rails.env.production?
        Rails.logger.info("[SmsSender] not configured; login code for #{phone} is #{code}")
        return
      end

      post(
        "PhoneNumbers" => phone.to_s.delete_prefix("+"),
        "SignName" => SIGN_NAME,
        "TemplateCode" => template_code,
        "TemplateParam" => JSON.generate({ "code" => code.to_s })
      )
    end

    def configured?
      access_key_id.present? && access_key_secret.present? && template_code.present?
    end

    private

    def post(action_params)
      params = action_params.merge(
        "Action" => "SendSms",
        "Version" => API_VERSION,
        "Format" => "JSON",
        "AccessKeyId" => access_key_id,
        "SignatureMethod" => "HMAC-SHA1",
        "SignatureVersion" => "1.0",
        "SignatureNonce" => SecureRandom.hex(16),
        "Timestamp" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      )
      params["Signature"] = signature(params)

      body = parse(http_post(params))

      # Aliyun answers 200 with a Code field regardless of outcome — an HTTP
      # status check alone would report every rejection as a success.
      return body if body["Code"] == "OK"

      # Message is Chinese prose from Aliyun ("触发天级流控Permits:10"), which is
      # the most useful thing we can put in front of the user; Code is what to
      # search their docs for.
      raise Error, "#{body['Code']}: #{body['Message']}"
    end

    def http_post(params)
      uri = URI(ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri)
      # Standard form encoding. The signature is computed over Aliyun's own
      # canonicalization of the decoded values, not over these bytes, so the
      # body only has to decode back to the same pairs.
      request.set_form_data(params)
      http.request(request).body
    rescue Net::OpenTimeout, Net::ReadTimeout, SystemCallError, OpenSSL::SSL::SSLError, IOError => e
      raise Error, "SMS gateway unreachable (#{e.class})"
    end

    def parse(raw)
      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      raise Error, "SMS gateway returned an unreadable response"
    end

    # RPC-style signature: sort the params, percent-encode each key and value,
    # join, then percent-encode that whole string again inside
    # "POST&%2F&<encoded>". The secret is used with a trailing "&".
    def signature(params)
      sorted = params.sort.map { |k, v| "#{percent_encode(k)}=#{percent_encode(v)}" }.join("&")
      string_to_sign = "POST&#{percent_encode('/')}&#{percent_encode(sorted)}"
      Base64.strict_encode64(
        OpenSSL::HMAC.digest("sha1", "#{access_key_secret}&", string_to_sign)
      )
    end

    # RFC 3986, which CGI.escape is not: it emits "+" for space and leaves "~"
    # encoded. Getting any of these three wrong produces a signature Aliyun
    # rejects with SignatureDoesNotMatch and no further hint.
    def percent_encode(str)
      CGI.escape(str.to_s).gsub("+", "%20").gsub("*", "%2A").gsub("%7E", "~")
    end

    # Read at call time, not at boot: ginger injects these into the container's
    # environment, and a constant frozen at load would make a config fix
    # require a redeploy rather than a restart.
    def access_key_id = ENV["ALIYUN_ACCESS_KEY_ID"].presence || ENV["ACCESS_KEY_ID"]
    def access_key_secret = ENV["ALIYUN_ACCESS_KEY_SECRET"].presence || ENV["ACCESS_KEY_SECRET"]
    def template_code = ENV["ALIYUN_SMS_TEMPLATE_CODE"]
  end
end
