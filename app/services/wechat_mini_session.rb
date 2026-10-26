class WechatMiniSession
  class Error < StandardError; end

  ENDPOINT = "https://api.weixin.qq.com/sns/jscode2session"

  # Exchanges a miniprogram js_code. session_key is never returned or logged.
  def self.exchange(js_code)
    appid = ENV["WECHAT_MINI_APPID"].to_s
    secret = ENV["WECHAT_MINI_SECRET"].to_s
    raise Error, "not configured" if appid.blank? || secret.blank?

    uri = URI(ENDPOINT)
    uri.query = URI.encode_www_form(appid: appid, secret: secret, js_code: js_code, grant_type: "authorization_code")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    body = JSON.parse(response.body)
    openid = body["openid"].presence
    raise Error, "wechat login failed" if openid.blank? || body["errcode"].to_i != 0

    { "openid" => openid, "unionid" => body["unionid"].presence }
  rescue JSON::ParserError, SocketError, Timeout::Error, Errno::ECONNREFUSED, EOFError
    raise Error, "wechat login failed"
  end
end
