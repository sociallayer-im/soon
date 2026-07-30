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

  test "secret_key round-trips (stored plaintext by decision, masked at the API boundary)" do
    user = create_user
    setting = StripeSetting.create!(user: user, name: "K", secret_key: "sk_live_supersecret9999")
    assert_equal "sk_live_supersecret9999", setting.reload.secret_key
  end

  test "masked_key exposes only the tail" do
    user = create_user
    setting = StripeSetting.create!(user: user, name: "K", secret_key: "sk_live_supersecret9999")
    assert_equal "…9999", setting.masked_key
  end

  test "a publishable key is rejected with a message that names the mistake" do
    setting = StripeSetting.new(user: create_user, name: "Oops", secret_key: "pk_test_abc123")
    assert_not setting.valid?
    assert_match(/publishable key/, setting.errors.full_messages.join)
    assert_match(/sk_|rk_/, setting.errors.full_messages.join, "must say what to use instead")
  end

  test "a user can hold multiple keys" do
    user = create_user
    StripeSetting.create!(user: user, name: "A", secret_key: "sk_live_a")
    StripeSetting.create!(user: user, name: "B", secret_key: "sk_test_b")
    assert_equal 2, user.stripe_settings.count
  end
end
