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
      domain: domain, address: key.address.to_s, uri: "http://#{domain}", chain_id: 1,
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

  test "verify_wallet accepts sonic.sola.town, which is a separate apex not a sola.day subdomain" do
    key = Eth::Key.new
    message, signature = signed_siwe_message(key, mint_nonce, domain: "sonic.sola.town")
    post "/api/v1/auth/verify_wallet", params: { message: message, signature: signature }
    assert_response :success
    assert json_response["token"].present?, "a real session, not just a 200"
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

  # Google moved to /auth/verify_google (the token is verified server-side
  # against Google itself) and Solana died with the standalone auth app. The
  # branches are gone so NEXT_TOKEN can no longer mint a session for an
  # arbitrary email — a valid secret with a non-WeChat identity is an error.
  test "trusted_signin no longer accepts email or sol identities" do
    with_next_token("s3cret") do
      assert_no_difference "User.count" do
        post "/api/v1/auth/trusted_signin", params: { next_token: "s3cret", email: "google@test.com" }
        assert_response :unprocessable_entity

        post "/api/v1/auth/trusted_signin", params: { next_token: "s3cret", sol_address: "So1anaAddre55" }
        assert_response :unprocessable_entity
      end
    end
  end

  test "trusted_signin with a wechat identity creates/finds the account" do
    with_next_token("s3cret") do
      assert_difference "User.count", 1 do
        post "/api/v1/auth/trusted_signin",
          params: { next_token: "s3cret", wechat_openid: "o_abc", wechat_unionid: "u_abc" }
      end
      assert_response :success
      user = User.find_by(wechat_unionid: "u_abc")
      assert user
      assert_equal "o_abc", user.wechat_openid
      assert_nil user.email

      # A second appid gives the same person a different openid; the unionid is
      # what has to keep them on one account.
      assert_no_difference "User.count" do
        post "/api/v1/auth/trusted_signin",
          params: { next_token: "s3cret", wechat_openid: "o_from_miniprogram", wechat_unionid: "u_abc" }
      end
      assert_equal "o_abc", user.reload.wechat_openid
    end
  end

  test "trusted_signin back-fills the unionid onto an openid-only account" do
    # What an account created before the 开放平台 binding looks like.
    user = User.create!(wechat_openid: "o_legacy")

    with_next_token("s3cret") do
      assert_no_difference "User.count" do
        post "/api/v1/auth/trusted_signin",
          params: { next_token: "s3cret", wechat_openid: "o_legacy", wechat_unionid: "u_legacy" }
      end
      assert_response :success
    end

    assert_equal "u_legacy", user.reload.wechat_unionid
  end

  test "trusted_signin with only a wechat_openid works" do
    with_next_token("s3cret") do
      assert_difference "User.count", 1 do
        post "/api/v1/auth/trusted_signin", params: { next_token: "s3cret", wechat_openid: "o_only" }
      end
      assert_response :success
      assert_nil User.find_by(wechat_openid: "o_only").wechat_unionid
    end
  end

  test "trusted_signin never repoints an existing wechat identifier" do
    # Two people, one already holding the openid. A payload pairing that openid
    # with someone else's unionid must not move it.
    User.create!(wechat_openid: "o_one", wechat_unionid: "u_one")
    User.create!(wechat_unionid: "u_two")

    with_next_token("s3cret") do
      post "/api/v1/auth/trusted_signin",
        params: { next_token: "s3cret", wechat_openid: "o_one", wechat_unionid: "u_two" }
      assert_response :success
    end

    assert_equal "u_one", User.find_by(wechat_openid: "o_one").wechat_unionid
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

  # --- binding an in-use address from a fresh WeChat account merges ---------
  #
  # Signing in through a second channel must not leave one person holding two
  # accounts. The WeChat account is created empty and is deleted by the merge,
  # so every guard below is about keeping that deletion safe.

  def fresh_wechat_user(openid: "o_new", unionid: "u_new")
    User.create!(wechat_openid: openid, wechat_unionid: unionid)
  end

  def bind_code_for(email)
    AuthCode.create!(recipient: email, recipient_type: "email", context: "bind_email", code: "ABC123")
  end

  test "binding an in-use email from an unregistered WeChat account merges into it" do
    existing = create_user(email: "me@test.com", name: "alice-wong")
    wechat = fresh_wechat_user
    bind_code_for("me@test.com")

    assert_difference "User.count", -1 do
      post "/api/v1/auth/bind_email", params: { email: "me@test.com", code: "ABC123" },
        headers: auth_headers(wechat)
    end
    assert_response :success

    # The caller is now a different account, so it gets a token to replace the
    # one it sent — a profile payload would leave it on a deleted user.
    assert json_response["token"].present?
    assert_equal true, json_response["merged"]
    assert_equal existing.id, json_response["user"]["id"]

    assert_not User.exists?(wechat.id), "the throwaway WeChat account is gone"
    assert_equal "o_new", existing.reload.wechat_openid
    assert_equal "u_new", existing.wechat_unionid
    assert_equal "alice-wong", existing.name, "the surviving account keeps its own profile"
  end

  # The point of the whole feature: the next WeChat login must land on the
  # merged account instead of minting a second one.
  test "after a merge the same WeChat identity signs back into the merged account" do
    existing = create_user(email: "me@test.com")
    wechat = fresh_wechat_user
    bind_code_for("me@test.com")

    post "/api/v1/auth/bind_email", params: { email: "me@test.com", code: "ABC123" },
      headers: auth_headers(wechat)
    assert_response :success

    with_next_token("s3cret") do
      assert_no_difference "User.count" do
        post "/api/v1/auth/trusted_signin",
          params: { next_token: "s3cret", wechat_openid: "o_new", wechat_unionid: "u_new" }
      end
      assert_response :success
      assert_equal existing.id, json_response["user"]["id"]
    end
  end

  # Picking a username closes the merge window — the account is a real one now,
  # and deleting it could throw away whatever the user has already done.
  test "a WeChat account that already registered a name will not merge" do
    create_user(email: "me@test.com")
    wechat = User.create!(wechat_openid: "o_new", name: "bob-zhang")
    bind_code_for("me@test.com")

    assert_no_difference "User.count" do
      post "/api/v1/auth/bind_email", params: { email: "me@test.com", code: "ABC123" },
        headers: auth_headers(wechat)
    end
    assert_response :unprocessable_entity
    assert_nil wechat.reload.email
  end

  # Nothing server-side requires a name before writing, so a nameless wallet
  # account may be years old and full of data. Only WeChat accounts merge.
  test "a nameless wallet account will not merge into an in-use email" do
    create_user(email: "me@test.com")
    wallet = User.create!(eth: "0x#{SecureRandom.hex(20)}")
    bind_code_for("me@test.com")

    assert_no_difference "User.count" do
      post "/api/v1/auth/bind_email", params: { email: "me@test.com", code: "ABC123" },
        headers: auth_headers(wallet)
    end
    assert_response :unprocessable_entity
  end

  # Overwriting the target's WeChat identity would aim someone else's next
  # login at this account; keeping ours elsewhere would recreate the duplicate.
  test "will not merge into an account that already has a WeChat identity" do
    create_user(email: "me@test.com").update!(wechat_openid: "o_theirs")
    wechat = fresh_wechat_user
    bind_code_for("me@test.com")

    assert_no_difference "User.count" do
      post "/api/v1/auth/bind_email", params: { email: "me@test.com", code: "ABC123" },
        headers: auth_headers(wechat)
    end
    assert_response :unprocessable_entity
    assert_equal "o_theirs", User.find_by(email: "me@test.com").wechat_openid
  end

  # The code is what proves the person owns the address; without it a WeChat
  # user could type any email and swallow that account.
  test "a merge still requires a valid bind-context code" do
    create_user(email: "me@test.com")
    wechat = fresh_wechat_user
    bind_code_for("me@test.com")

    assert_no_difference "User.count" do
      post "/api/v1/auth/bind_email", params: { email: "me@test.com", code: "WRONG1" },
        headers: auth_headers(wechat)
    end
    assert_response :unauthorized
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
