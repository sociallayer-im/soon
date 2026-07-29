require "test_helper"

# SIWE wallet login, trusted signin (Google/Solana via the auth service's
# shared secret), and binding an email to a wallet-first account.
class Api::V1::WalletAuthTest < ActionDispatch::IntegrationTest
  def mint_nonce
    get "/api/v1/auth/nonce"
    assert_response :success
    json_response["nonce"]
  end

  # Builds and signs a real EIP-4361 message with the given key.
  def signed_siwe_message(key, nonce, issued_at: Time.now.utc.iso8601, domain: "localhost")
    message = Siwe::Message.new(
      domain, key.address.to_s, "http://#{domain}", "1",
      nonce: nonce, issued_at: issued_at
    ).prepare_message
    signature = key.personal_sign(message)
    signature = "0x#{signature}" unless signature.start_with?("0x")
    [message, signature]
  end

  test "nonce mints a stored single-use nonce" do
    assert_difference "AuthCode.count", 1 do
      nonce = mint_nonce
      assert nonce.present?
      assert AuthCode.active.for_context("siwe_nonce").exists?(code: nonce)
    end
  end

  test "verify_wallet signs in with a valid SIWE message, creating the account" do
    key = Eth::Key.new
    message, signature = signed_siwe_message(key, mint_nonce)

    assert_difference "User.count", 1 do
      post "/api/v1/auth/verify_wallet", params: { message: message, signature: signature }
    end
    assert_response :success
    assert json_response["token"].present?

    user = User.find_by(eth: key.address.to_s.downcase)
    assert user, "user should be created with the lowercased address"
    assert_nil user.email
    assert_nil user.name

    # the JWT works
    get "/api/v1/users/me", headers: { "Authorization" => "Bearer #{json_response["token"]}" }
    assert_response :success
  end

  test "verify_wallet finds the same account on repeat logins" do
    key = Eth::Key.new
    message, signature = signed_siwe_message(key, mint_nonce)
    post "/api/v1/auth/verify_wallet", params: { message: message, signature: signature }
    first_id = json_response["user"]["id"]

    message, signature = signed_siwe_message(key, mint_nonce)
    assert_no_difference "User.count" do
      post "/api/v1/auth/verify_wallet", params: { message: message, signature: signature }
    end
    assert_equal first_id, json_response["user"]["id"]
  end

  test "verify_wallet rejects a nonce we never minted" do
    key = Eth::Key.new
    message, signature = signed_siwe_message(key, SecureRandom.hex(16))

    post "/api/v1/auth/verify_wallet", params: { message: message, signature: signature }
    assert_response :unauthorized
  end

  test "verify_wallet rejects a replayed message (nonce is single-use)" do
    key = Eth::Key.new
    message, signature = signed_siwe_message(key, mint_nonce)

    post "/api/v1/auth/verify_wallet", params: { message: message, signature: signature }
    assert_response :success
    post "/api/v1/auth/verify_wallet", params: { message: message, signature: signature }
    assert_response :unauthorized
  end

  test "verify_wallet rejects a signature from a different key" do
    key = Eth::Key.new
    imposter = Eth::Key.new
    message, _ = signed_siwe_message(key, mint_nonce)
    _, forged = signed_siwe_message(imposter, mint_nonce)

    assert_no_difference "User.count" do
      post "/api/v1/auth/verify_wallet", params: { message: message, signature: forged }
    end
    assert_response :unauthorized
  end

  test "verify_wallet rejects garbage input" do
    post "/api/v1/auth/verify_wallet", params: { message: "not a siwe message", signature: "0x00" }
    assert_response :unauthorized
  end

  test "verify_wallet accepts a message whose domain is a known auth frontend" do
    key = Eth::Key.new
    message, signature = signed_siwe_message(key, mint_nonce, domain: "auth.sola.day")

    assert_difference "User.count", 1 do
      post "/api/v1/auth/verify_wallet", params: { message: message, signature: signature }
    end
    assert_response :success
  end

  test "verify_wallet rejects a message whose domain is not an allowlisted frontend" do
    key = Eth::Key.new
    message, signature = signed_siwe_message(key, mint_nonce, domain: "evil-phishing-site.com")

    assert_no_difference "User.count" do
      post "/api/v1/auth/verify_wallet", params: { message: message, signature: signature }
    end
    assert_response :unauthorized
    # the nonce must not be burned by a rejected domain — a legitimate retry
    # from an allowlisted domain with the same nonce should still work
    assert AuthCode.active.for_context("siwe_nonce").exists?(code: message[/Nonce: (\S+)/, 1])
  end

  test "trusted_signin requires the shared secret" do
    with_next_token("s3cret") do
      post "/api/v1/auth/trusted_signin", params: { next_token: "wrong", email: "g@test.com" }
      assert_response :unauthorized
    end
  end

  test "trusted_signin is disabled when no secret is configured" do
    with_next_token(nil) do
      post "/api/v1/auth/trusted_signin", params: { next_token: "", email: "g@test.com" }
      assert_response :unauthorized
    end
  end

  test "trusted_signin with an email creates/finds the account (Google flow)" do
    with_next_token("s3cret") do
      assert_difference "User.count", 1 do
        post "/api/v1/auth/trusted_signin", params: { next_token: "s3cret", email: "Google@Test.com" }
      end
      assert_response :success
      assert json_response["token"].present?
      assert User.exists?(email: "google@test.com")

      assert_no_difference "User.count" do
        post "/api/v1/auth/trusted_signin", params: { next_token: "s3cret", email: "google@test.com" }
      end
    end
  end

  test "trusted_signin with a sol_address creates/finds the account (Solana flow)" do
    with_next_token("s3cret") do
      assert_difference "User.count", 1 do
        post "/api/v1/auth/trusted_signin", params: { next_token: "s3cret", sol_address: "So1anaAddre55" }
      end
      assert_response :success
      user = User.find_by(sol: "So1anaAddre55")
      assert user
      assert_nil user.email
    end
  end

  test "trusted_signin without an identity is rejected" do
    with_next_token("s3cret") do
      post "/api/v1/auth/trusted_signin", params: { next_token: "s3cret" }
      assert_response :unprocessable_entity
    end
  end

  test "bind_email attaches a verified email to a wallet-first account" do
    user = User.create!(eth: "0x#{SecureRandom.hex(20)}")
    AuthCode.create!(recipient: "bindme@test.com", recipient_type: "email", context: "bind_email", code: "ABC123")

    post "/api/v1/auth/bind_email", params: { email: "BindMe@Test.com", code: "ABC123" },
      headers: auth_headers(user)
    assert_response :success
    assert_equal "bindme@test.com", user.reload.email
  end

  test "bind_email rejects a login-context code" do
    user = User.create!(eth: "0x#{SecureRandom.hex(20)}")
    AuthCode.create!(recipient: "bindme@test.com", recipient_type: "email", context: "login", code: "ABC123")

    post "/api/v1/auth/bind_email", params: { email: "bindme@test.com", code: "ABC123" },
      headers: auth_headers(user)
    assert_response :unauthorized
    assert_nil user.reload.email
  end

  test "bind_email rejects an email already on another account" do
    other = create_user
    user = User.create!(eth: "0x#{SecureRandom.hex(20)}")
    AuthCode.create!(recipient: other.email, recipient_type: "email", context: "bind_email", code: "ABC123")

    post "/api/v1/auth/bind_email", params: { email: other.email, code: "ABC123" },
      headers: auth_headers(user)
    assert_response :unprocessable_entity
    assert_nil user.reload.email
  end

  test "bind_email refuses to change an existing email" do
    user = create_user
    AuthCode.create!(recipient: "new@test.com", recipient_type: "email", context: "bind_email", code: "ABC123")

    post "/api/v1/auth/bind_email", params: { email: "new@test.com", code: "ABC123" },
      headers: auth_headers(user)
    assert_response :unprocessable_entity
  end

  test "bind_email requires authentication" do
    post "/api/v1/auth/bind_email", params: { email: "x@test.com", code: "ABC123" }
    assert_response :unauthorized
  end

  test "request_code with bind context mints a bind-only code" do
    post "/api/v1/auth/request_code", params: { email: "bindme@test.com", context: "bind_email" }
    assert_response :success
    assert AuthCode.active.for_recipient("bindme@test.com").for_context("bind_email").exists?
    assert_not AuthCode.for_recipient("bindme@test.com").for_context("login").exists?
  end

  test "a wallet-only user is valid but a user with no identity is not" do
    assert User.new(eth: "0xabc").valid?
    assert User.new(sol: "abc").valid?
    refute User.new.valid?
    refute User.new(nickname: "x").valid?
  end

  private

  def with_next_token(value)
    original = ENV["NEXT_TOKEN"]
    value.nil? ? ENV.delete("NEXT_TOKEN") : ENV["NEXT_TOKEN"] = value
    yield
  ensure
    original.nil? ? ENV.delete("NEXT_TOKEN") : ENV["NEXT_TOKEN"] = original
  end
end
