# The phone authorization code is distinct from wx.login's code. Only the
# server exchanges it; client-supplied phone numbers are never trusted here.
class WechatMiniprogramPhone
  class Unavailable < StandardError; end
  class InvalidCode < StandardError; end

  def self.phone_number(code)
    appid = ENV["WECHAT_MINIPROGRAM_APP_ID"].to_s
    secret = ENV["WECHAT_MINIPROGRAM_APP_SECRET"].to_s
    raise Unavailable if appid.blank? || secret.blank?
    client = HTTPX.with(timeout: { operation_timeout: 10 })
    key = "wechat-mini-access-token:#{appid}"
    token = Rails.cache.fetch(key, expires_in: 100.minutes) do
      data = parse(client.post("https://api.weixin.qq.com/cgi-bin/stable_token",
        json: {grant_type: "client_credential", appid: appid, secret: secret, force_refresh: false}))
      raise Unavailable if data["access_token"].blank?
      data["access_token"]
    end
    data = parse(client.post("https://api.weixin.qq.com/wxa/business/getuserphonenumber",
      params: {access_token: token}, json: {code: code}))
    if [40001, 40014, 42001].include?(data["errcode"].to_i)
      Rails.cache.delete(key)
      raise Unavailable
    end
    raise InvalidCode unless data["errcode"].to_i.zero?
    info = data["phone_info"] || {}
    raise InvalidCode unless info.dig("watermark", "appid") == appid
    raise InvalidCode unless info["countryCode"].to_s == "86"
    phone = PhoneNumber.normalize(info["purePhoneNumber"].to_s)
    raise InvalidCode if phone.blank?
    phone
  end

  def self.parse(response)
    raise Unavailable if response.is_a?(HTTPX::ErrorResponse) || response.status != 200
    data = JSON.parse(response.body.to_s)
    raise Unavailable unless data.is_a?(Hash)
    data
  rescue JSON::ParserError
    raise Unavailable
  end
  private_class_method :parse
end
