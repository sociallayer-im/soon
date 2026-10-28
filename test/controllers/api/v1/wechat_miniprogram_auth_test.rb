require "test_helper"

class Api::V1::WechatMiniprogramAuthTest < ActionDispatch::IntegrationTest
  test "requires a code" do
    post "/api/v1/auth/wechat_miniprogram", params: {}
    assert_response :unprocessable_entity
  end

  test "verified identity signs in and ignores client asserted identifiers" do
    WechatMiniprogramAuth.stub(:identity, { openid: "mini_#{unique_suffix}", unionid: nil }) do
      assert_difference "User.count", 1 do
        post "/api/v1/auth/wechat_miniprogram", params: { js_code: "code", wechat_openid: "spoofed", wechat_unionid: "spoofed" }
      end
      assert_response :success
      assert json_response["token"].present?
      user = User.find(json_response.dig("user", "id"))
      assert_not_equal "spoofed", user.wechat_openid
      assert_nil user.wechat_unionid
      assert_not response.body.include?("session_key")
      assert_no_difference "User.count" do
        post "/api/v1/auth/wechat_miniprogram", params: { js_code: "next-code" }
      end
      assert_equal user.id, json_response.dig("user", "id")
    end
  end

  test "verified unionid reuses an existing account" do
    user = User.create!(wechat_unionid: "union_#{unique_suffix}")
    WechatMiniprogramAuth.stub(:identity, { openid: "mini_#{unique_suffix}", unionid: user.wechat_unionid }) do
      assert_no_difference "User.count" do
        post "/api/v1/auth/wechat_miniprogram", params: { js_code: "code" }
      end
      assert_response :success
      assert_equal user.id, json_response.dig("user", "id")
    end
  end

  test "invalid code does not create an account" do
    WechatMiniprogramAuth.stub(:identity, ->(*) { raise WechatMiniprogramAuth::InvalidCode }) do
      assert_no_difference "User.count" do
        post "/api/v1/auth/wechat_miniprogram", params: { js_code: "expired" }
      end
      assert_response :unauthorized
    end
  end

  test "missing configuration is a structured service error" do
    WechatMiniprogramAuth.stub(:identity, ->(*) { raise WechatMiniprogramAuth::Unavailable }) do
      post "/api/v1/auth/wechat_miniprogram", params: { js_code: "code" }
      assert_response :service_unavailable
      assert_equal "WECHAT_UNAVAILABLE", json_response["code"]
    end
  end
end
