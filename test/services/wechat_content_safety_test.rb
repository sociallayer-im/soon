require "test_helper"

class WechatContentSafetyTest < ActiveSupport::TestCase
  setup do
    @saved = ENV.to_h.slice("WECHAT_MINIPROGRAM_APP_ID", "WECHAT_MINIPROGRAM_APP_SECRET")
    ENV["WECHAT_MINIPROGRAM_APP_ID"] = "safety-test"
    ENV["WECHAT_MINIPROGRAM_APP_SECRET"] = "test-only"
    Rails.cache.delete("wechat-mini-access-token:safety-test")
  end
  teardown do
    %w[WECHAT_MINIPROGRAM_APP_ID WECHAT_MINIPROGRAM_APP_SECRET].each { |key| ENV.delete(key) }
    @saved.each { |key, value| ENV[key] = value }
  end

  def check_response(body)
    response = Struct.new(:status, :body)
    client = Object.new
    client.define_singleton_method(:post) do |url, **options|
      if url.end_with?("stable_token")
        response.new(200, {access_token: "test-token"}.to_json)
      else
        raise "untrusted identity" unless options[:json][:openid] == "server-openid"
        response.new(200, body.to_json)
      end
    end
    HTTPX.stub(:with, client) do
      WechatContentSafety.check!(user: Struct.new(:wechat_openid).new("server-openid"), content: "test content")
    end
  end
  test "accepts only explicit pass" do
    assert check_response({errcode: 0, result: {suggest: "pass"}})
  end
  test "blocks risky and review results" do
    %w[risky review].each do |suggest|
      assert_raises(WechatContentSafety::Rejected) { check_response({errcode: 0, result: {suggest: suggest}}) }
    end
    assert_raises(WechatContentSafety::Rejected) { check_response({errcode: 87014}) }
  end
  test "fails closed on missing result or upstream error" do
    [{errcode: 0}, {errcode: 40001}, {errcode: 45009}].each do |body|
      assert_raises(WechatContentSafety::Unavailable) { check_response(body) }
    end
  end
end
