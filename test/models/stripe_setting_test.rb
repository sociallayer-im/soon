require "test_helper"

class StripeSettingTest < ActiveSupport::TestCase
  include FactoryHelpers

  test "mode is auto-detected from the key prefix" do
    user = create_user
    live = StripeSetting.create!(user: user, name: "Live", secret_key: "sk_live_abc123")
    test_key = StripeSetting.create!(user: user, name: "Test", secret_key: "sk_test_abc123")
    restricted_test = StripeSetting.create!(user: user, name: "RK", secret_key: "rk_test_abc123")

    assert_equal "live", live.mode
    assert_equal "test", test_key.mode
    assert_equal "test", restricted_test.mode
    assert restricted_test.test_mode?
  end

  test "secret_key is encrypted at rest but readable through the model" do
    user = create_user
    setting = StripeSetting.create!(user: user, name: "K", secret_key: "sk_live_supersecret9999")

    assert_equal "sk_live_supersecret9999", setting.reload.secret_key
    raw = ActiveRecord::Base.connection.select_value(
      "SELECT secret_key FROM stripe_settings WHERE id = #{ActiveRecord::Base.connection.quote(setting.id)}"
    )
    assert_not_includes raw, "supersecret", "the raw column must not contain the plaintext key"
  end

  test "masked_key exposes only the tail" do
    user = create_user
    setting = StripeSetting.create!(user: user, name: "K", secret_key: "sk_live_supersecret9999")
    assert_equal "…9999", setting.masked_key
  end

  test "a user can hold multiple keys" do
    user = create_user
    StripeSetting.create!(user: user, name: "A", secret_key: "sk_live_a")
    StripeSetting.create!(user: user, name: "B", secret_key: "sk_test_b")
    assert_equal 2, user.stripe_settings.count
  end
end
