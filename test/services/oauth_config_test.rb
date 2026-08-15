require "test_helper"

class OauthConfigTest < ActiveSupport::TestCase
  def with_key_env(value)
    previous = ENV["OAUTH_RSA_PRIVATE_KEY"]
    ENV["OAUTH_RSA_PRIVATE_KEY"] = value
    OauthConfig.reset!
    yield
  ensure
    ENV["OAUTH_RSA_PRIVATE_KEY"] = previous
    OauthConfig.reset!
  end

  # A PEM is multi-line and .env files are not, so the spelling that reaches
  # the container depends on whose parser touched it. All three must work or a
  # deploy fails with an opaque OpenSSL error that names neither ginger nor the
  # key.
  test "the key is read as base64, as escaped newlines, and as a real PEM" do
    pem = FactoryHelpers.rsa_key.to_pem
    expected = FactoryHelpers.rsa_key.public_key.to_der

    with_key_env(Base64.strict_encode64(pem)) do
      assert_equal expected, OauthConfig.public_key.to_der
    end
    with_key_env(pem.gsub("\n", '\n')) do
      assert_equal expected, OauthConfig.public_key.to_der
    end
    with_key_env(pem) do
      assert_equal expected, OauthConfig.public_key.to_der
    end
  end

  test "a malformed key logs and disables signing rather than crashing the boot" do
    with_key_env("not a key at all") do
      assert_nil OauthConfig.private_key
      assert_not OauthConfig.configured?
      assert_equal [], OauthConfig.jwks[:keys]
    end
  end

  test "the key id is derived from the key and appears in the JWKS" do
    with_key_env(FactoryHelpers.rsa_key.to_pem) do
      assert_equal OauthConfig.key_id, OauthConfig.jwks[:keys].first[:kid]
    end
  end
end
