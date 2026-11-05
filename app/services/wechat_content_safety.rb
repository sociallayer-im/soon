# Synchronous text gate: never publish unchecked text when the gateway fails.
class WechatContentSafety
  class Rejected < StandardError; end
  class RejectedImage < StandardError; end
  class Unavailable < StandardError; end

  def self.check!(user:, content:, scene: 2)
    return if content.blank?
    client, token, key = gateway
    # v2 requires an identity issued by this app. Email/SMS-only accounts use
    # the identity-independent text endpoint; never trust a client openid.
    body = { content: content }
    body.merge!(version: 2, scene: scene, openid: user.wechat_openid) if user.wechat_openid.present?
    data = parse(client.post("https://api.weixin.qq.com/wxa/msg_sec_check",
      params: { access_token: token }, json: body))
    # v2 requires a recent WeChat visit. A persistent app session can outlive
    # that window, or carry an identity from an older AppID. The independently
    # verified identity-free endpoint must still check the same content; never
    # interpret an identity error as a content pass.
    if body[:version] == 2 && [40003, 61010].include?(data["errcode"].to_i)
      body = { content: content }
      data = parse(client.post("https://api.weixin.qq.com/wxa/msg_sec_check",
        params: { access_token: token }, json: body))
    end
    if [40001, 40014, 42001].include?(data["errcode"].to_i)
      Rails.cache.delete(key)
      raise Unavailable
    end
    raise Rejected if data["errcode"] == 87014
    raise Unavailable unless data["errcode"] == 0
    if body[:version] == 2
      suggestion = data.dig("result", "suggest")
      raise Unavailable if suggestion.blank?
      raise Rejected unless suggestion == "pass"
    end
    true
  rescue JSON::ParserError, HTTPX::Error
    raise Unavailable
  end

  def self.check_image!(bytes)
    client, token, key = gateway
    require "tempfile"
    Tempfile.create(["safety-image", ".jpg"]) do |file|
      file.binmode
      file.write(bytes)
      file.rewind
      data = parse(client.post("https://api.weixin.qq.com/wxa/img_sec_check",
        params: { access_token: token }, form: { media: file }))
      if [40001, 40014, 42001].include?(data["errcode"].to_i)
        Rails.cache.delete(key)
        raise Unavailable
      end
      raise Rejected if data["errcode"] == 87014
      raise Unavailable unless data["errcode"] == 0
    end
    true
  rescue JSON::ParserError, HTTPX::Error
    raise Unavailable
  end

  def self.gateway
    appid = ENV.fetch("WECHAT_MINIPROGRAM_APP_ID", "")
    secret = ENV.fetch("WECHAT_MINIPROGRAM_APP_SECRET", "")
    raise Unavailable if appid.blank? || secret.blank?
    client = HTTPX.with(timeout: { operation_timeout: 10 })
    key = "wechat-mini-access-token:#{appid}"
    token = Rails.cache.fetch(key, expires_in: 100.minutes) do
      data = parse(client.post("https://api.weixin.qq.com/cgi-bin/stable_token",
        json: { grant_type: "client_credential", appid: appid, secret: secret, force_refresh: false }))
      raise Unavailable if data["access_token"].blank?
      data["access_token"]
    end
    [client, token, key]
  end
  private_class_method :gateway

  def self.parse(response)
    raise Unavailable if response.is_a?(HTTPX::ErrorResponse) || response.status != 200
    data = JSON.parse(response.body.to_s)
    raise Unavailable unless data.is_a?(Hash)
    data
  end
  private_class_method :parse
end
