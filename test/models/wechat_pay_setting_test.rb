require "test_helper"

class WechatPaySettingTest < ActiveSupport::TestCase
  test "platform_default is the platform-owned active row, not an organizer's" do
    organizer_owned = create_wechat_pay_setting(user: create_user)
    platform = create_wechat_pay_setting

    assert_equal platform.id, WechatPaySetting.platform_default.id
    assert_not_equal organizer_owned.id, WechatPaySetting.platform_default.id
  end

  test "platform_default ignores an invalidated merchant" do
    create_wechat_pay_setting(status: "invalid")

    assert_nil WechatPaySetting.platform_default
  end

  # The single most likely credential mistake: 微信商户平台 hands you
  # apiclient_cert.pem and apiclient_key.pem in the same download, and only the
  # second one can sign. Pasting the certificate produces a row that saves
  # cleanly and then fails on every outbound request with an OpenSSL error far
  # from the cause.
  test "a certificate pasted in place of the private key is rejected at save" do
    setting = WechatPaySetting.new(
      name: "M", mchid: "1234567890", app_id: "wxapp", cert_serial: "AABB",
      private_key: "-----BEGIN CERTIFICATE-----\nMIIEJDCCAwyg\n-----END CERTIFICATE-----\n",
      apiv3_key: SecureRandom.alphanumeric(32)
    )

    assert_not setting.valid?
    assert_match "apiclient_key.pem", setting.errors[:private_key].first
  end

  # APIv3 keys are literal 32-byte AES-256 keys. A shorter one only fails
  # inside AES-GCM while decrypting a callback, where the symptom is silent
  # webhook errors and payments that never confirm.
  test "an APIv3 key that is not 32 bytes is rejected at save" do
    setting = WechatPaySetting.new(
      name: "M", mchid: "1234567890", app_id: "wxapp", cert_serial: "AABB",
      private_key: FactoryHelpers.rsa_key.to_pem, apiv3_key: "tooshort"
    )

    assert_not setting.valid?
    assert_match "32 bytes", setting.errors[:apiv3_key].first
  end

  test "collecting_mchid prefers the sub-merchant, and service_provider? follows it" do
    platform = create_wechat_pay_setting
    sub = create_wechat_pay_setting(sub_mchid: "1900000109")

    assert_equal platform.mchid, platform.collecting_mchid
    assert_not platform.service_provider?
    assert_equal "1900000109", sub.collecting_mchid
    assert sub.service_provider?
  end
end
