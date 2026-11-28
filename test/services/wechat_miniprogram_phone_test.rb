require "test_helper"

class WechatMiniprogramPhoneTest < ActiveSupport::TestCase
  setup do
    @saved = ENV.to_h.slice("WECHAT_MINIPROGRAM_APP_ID", "WECHAT_MINIPROGRAM_APP_SECRET")
    ENV["WECHAT_MINIPROGRAM_APP_ID"] = "phone-test-app"
    ENV["WECHAT_MINIPROGRAM_APP_SECRET"] = "test-secret"
    Rails.cache.delete("wechat-mini-access-token:phone-test-app")
  end
  teardown do
    %w[WECHAT_MINIPROGRAM_APP_ID WECHAT_MINIPROGRAM_APP_SECRET].each { |key| ENV.delete(key) }
    @saved.each { |key, value| ENV[key] = value }
  end

  def with_phone_response(body)
    response = Struct.new(:status, :body)
    client = Object.new
    client.define_singleton_method(:post) do |url, **options|
      if url.end_with?("/stable_token")
        raise unless options[:json][:appid] == "phone-test-app"
        response.new(200, {access_token: "server-token"}.to_json)
      else
        raise unless options[:params][:access_token] == "server-token" && options[:json][:code] == "phone-code"
        response.new(200, body.to_json)
      end
    end
    HTTPX.stub(:with, client) { yield }
  end

  test "exchanges a dedicated phone code and normalizes the verified number" do
    with_phone_response(errcode: 0, phone_info: {purePhoneNumber: "13800138000", countryCode: "86", watermark: {appid: "phone-test-app"}}) do
      assert_equal "+8613800138000", WechatMiniprogramPhone.phone_number("phone-code")
    end
  end

  test "rejects a code for another app and invalid or expired codes" do
    [{errcode: 40029}, {errcode: 0, phone_info: {purePhoneNumber: "13800138000", countryCode: "86", watermark: {appid: "other-app"}}}].each do |body|
      with_phone_response(body) { assert_raises(WechatMiniprogramPhone::InvalidCode) { WechatMiniprogramPhone.phone_number("phone-code") } }
    end
  end

  test "missing credentials do not call WeChat" do
    ENV.delete("WECHAT_MINIPROGRAM_APP_SECRET")
    assert_raises(WechatMiniprogramPhone::Unavailable) { WechatMiniprogramPhone.phone_number("phone-code") }
  end
end
