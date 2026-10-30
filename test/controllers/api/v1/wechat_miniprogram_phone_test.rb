require "test_helper"

class Api::V1::WechatMiniprogramPhoneTest < ActionDispatch::IntegrationTest
  test "requires an authenticated WeChat account" do
    post "/api/v1/auth/wechat_miniprogram_phone", params: {phone_code: "code"}
    assert_response :unauthorized
    post "/api/v1/auth/wechat_miniprogram_phone", params: {phone_code: "code"}, headers: auth_headers(create_user)
    assert_response :forbidden
  end

  test "binds only the server verified number ignoring client asserted phone" do
    user = create_user(wechat_openid: "wx_#{unique_suffix}")
    WechatMiniprogramPhone.stub(:phone_number, "+8613800138000") do
      post "/api/v1/auth/wechat_miniprogram_phone", params: {phone_code: "code", phone: "+8613900139000"}, headers: auth_headers(user)
    end
    assert_response :success
    assert_equal "+8613800138000", user.reload.phone
  end

  test "existing phone account receives the WeChat identity and a new session" do
    source = create_user(email: nil, name: nil, wechat_openid: "wx_#{unique_suffix}")
    target = create_user(phone: "+8613800138001")
    WechatMiniprogramPhone.stub(:phone_number, target.phone) do
      post "/api/v1/auth/wechat_miniprogram_phone", params: {phone_code: "code"}, headers: auth_headers(source)
    end
    assert_response :success
    assert_equal target.id, json_response.dig("user", "id")
    assert json_response["merged"]
    assert_equal source.wechat_openid, target.reload.wechat_openid
  end

  test "invalid code does not bind a number" do
    user = create_user(wechat_openid: "wx_#{unique_suffix}")
    WechatMiniprogramPhone.stub(:phone_number, ->(*) { raise WechatMiniprogramPhone::InvalidCode }) do
      post "/api/v1/auth/wechat_miniprogram_phone", params: {phone_code: "expired"}, headers: auth_headers(user)
    end
    assert_response :unauthorized
    assert_nil user.reload.phone
  end
end
