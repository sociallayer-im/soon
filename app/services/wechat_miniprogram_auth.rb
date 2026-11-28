# Redeem wx.login's single-use code on the server. Never return session_key.
class WechatMiniprogramAuth
  class Unavailable < StandardError; end
  class InvalidCode < StandardError; end

  def self.identity(code)
    appid = ENV["WECHAT_MINIPROGRAM_APP_ID"].to_s
    secret = ENV["WECHAT_MINIPROGRAM_APP_SECRET"].to_s
    raise Unavailable if appid.empty? || secret.empty?

    response = HTTPX.with(timeout: { operation_timeout: 10 }).get(
      "https://api.weixin.qq.com/sns/jscode2session",
      params: { appid: appid, secret: secret, js_code: code, grant_type: "authorization_code" }
    )
    raise Unavailable if response.is_a?(HTTPX::ErrorResponse) || response.status != 200

    data = JSON.parse(response.body.to_s)
    raise InvalidCode unless data.is_a?(Hash) && data["errcode"].to_i.zero? && data["openid"].present?

    { appid: appid, openid: data["openid"], unionid: data["unionid"] }
  rescue JSON::ParserError
    raise Unavailable
  end
end
