require "test_helper"

class WechatMiniprogramAuthTest < ActiveSupport::TestCase
  setup do
    @saved = ENV.to_h.slice("WECHAT_MINIPROGRAM_APP_ID", "WECHAT_MINIPROGRAM_APP_SECRET")
    ENV["WECHAT_MINIPROGRAM_APP_ID"] = "test-app"
    ENV["WECHAT_MINIPROGRAM_APP_SECRET"] = "test-secret"
  end

  teardown do
    %w[WECHAT_MINIPROGRAM_APP_ID WECHAT_MINIPROGRAM_APP_SECRET].each { |key| ENV.delete(key) }
    @saved.each { |key, value| ENV[key] = value }
  end

  test "exchanges a code and excludes the session key" do
    response = Struct.new(:status, :body).new(200, { openid: "verified", unionid: "union", session_key: "private" }.to_json)
    client = Object.new
    client.define_singleton_method(:get) do |url, params:|
      raise unless url == "https://api.weixin.qq.com/sns/jscode2session" && params[:js_code] == "once" && params[:secret] == "test-secret" && params[:grant_type] == "authorization_code"
      response
    end
    HTTPX.stub(:with, client) do
      assert_equal({ openid: "verified", unionid: "union" }, WechatMiniprogramAuth.identity("once"))
    end
  end

  test "missing config fails before network" do
    ENV.delete("WECHAT_MINIPROGRAM_APP_SECRET")
    assert_raises(WechatMiniprogramAuth::Unavailable) { WechatMiniprogramAuth.identity("code") }
  end

  test "wechat rejection cannot become an identity" do
    client = Object.new
    client.define_singleton_method(:get) { |*args, **kwargs| Struct.new(:status, :body).new(200, '{"errcode":40029,"errmsg":"invalid code"}') }
    HTTPX.stub(:with, client) do
      assert_raises(WechatMiniprogramAuth::InvalidCode) { WechatMiniprogramAuth.identity("invalid") }
    end
  end
end
