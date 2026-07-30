require "test_helper"
require "ostruct"

# Stubs one level deeper than the controller tests (which stub the gateway
# itself) — these exist to catch stripe-ruby call-signature mistakes, which
# unit stubs above the gateway can never see.
class StripeGatewayTest < ActiveSupport::TestCase
  test "validate_key hits the singleton account endpoint: nil id, key in opts" do
    captured = nil
    fake = ->(id, opts) { captured = [ id, opts ]; OpenStruct.new(id: "acct_1") }

    Stripe::Account.stub :retrieve, fake do
      # rk_ keys matter here: passing the key AS the id only works for sk_
      # prefixes, and a non-nil/non-string id raises TypeError in stripe-ruby.
      assert_equal "acct_1", StripeGateway.validate_key("rk_test_abc")
    end
    assert_nil captured[0], "id must be nil to route to /v1/account"
    assert_equal "rk_test_abc", captured[1][:api_key]
  end

  test "validate_key maps stripe auth errors to InvalidKey" do
    raises = ->(_id, _opts) { raise Stripe::AuthenticationError.new("bad key") }
    Stripe::Account.stub :retrieve, raises do
      assert_raises(StripeGateway::InvalidKey) { StripeGateway.validate_key("sk_live_bad") }
    end
  end
end
