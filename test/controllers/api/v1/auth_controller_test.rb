require "test_helper"

class Api::V1::AuthControllerTest < ActionDispatch::IntegrationTest
  test "request_code creates an AuthCode for a known email" do
    user = create_user

    assert_difference "AuthCode.count", 1 do
      post "/api/v1/auth/request_code", params: { email: user.email }
    end
    assert_response :success
    assert_equal "Code sent", json_response["message"]
  end

  # The frontend's CODE_LENGTH and input maxLength are derived from this, so the
  # format is a contract, not an implementation detail. Zero-padding matters:
  # random_number can return 42, and an unpadded "42" would be a 2-digit code
  # that the 6-character input never lets the user finish typing.
  test "request_code mints a 6-digit numeric code, zero-padded" do
    100.times do
      AuthCode.delete_all
      post "/api/v1/auth/request_code", params: { email: "codeformat@test.com" }
      assert_response :success
      assert_match(/\A\d{6}\z/, AuthCode.last.code)
    end
  end

  test "a 6-digit code still dies after MAX_ATTEMPTS wrong guesses" do
    post "/api/v1/auth/request_code", params: { email: "guessme@test.com" }
    code = AuthCode.last
    wrong = code.code == "000000" ? "111111" : "000000"

    AuthCode::MAX_ATTEMPTS.times do
      post "/api/v1/auth/verify_code", params: { email: "guessme@test.com", code: wrong }
      assert_response :unauthorized
    end

    # Burned — even the correct code no longer works.
    assert code.reload.used?
    post "/api/v1/auth/verify_code", params: { email: "guessme@test.com", code: code.code }
    assert_response :unauthorized
  end

  test "request_code mints a code for an unknown email too — first login is signup" do
    assert_difference "AuthCode.count", 1 do
      post "/api/v1/auth/request_code", params: { email: "newcomer@test.com" }
    end
    assert_response :success
    assert_equal "Code sent", json_response["message"]
  end

  test "request_code invalidates prior unused codes so only the latest is valid" do
    user = create_user
    post "/api/v1/auth/request_code", params: { email: user.email }
    first = AuthCode.for_recipient(user.email).order(:created_at).last
    post "/api/v1/auth/request_code", params: { email: user.email }

    assert first.reload.used?, "the earlier code should be invalidated"
    assert_equal 1, AuthCode.active.for_recipient(user.email).count
  end

  test "verify_code burns the code after too many wrong attempts" do
    user = create_user
    AuthCode.create!(recipient: user.email, recipient_type: "email", context: "login", code: "ABC123")

    AuthCode::MAX_ATTEMPTS.times do
      post "/api/v1/auth/verify_code", params: { email: user.email, code: "WRONG1" }
      assert_response :unauthorized
    end
    # even the correct code no longer works — it was invalidated
    post "/api/v1/auth/verify_code", params: { email: user.email, code: "ABC123" }
    assert_response :unauthorized
  end

  test "verify_code ignores a code minted for a different context" do
    user = create_user
    AuthCode.create!(recipient: user.email, recipient_type: "email", context: "email_verification", code: "ABC123")

    post "/api/v1/auth/verify_code", params: { email: user.email, code: "ABC123" }
    assert_response :unauthorized
  end

  test "verify_code returns a JWT for a correct, unexpired code" do
    user = create_user
    code = AuthCode.create!(recipient: user.email, recipient_type: "email", context: "login", code: "ABC123")

    post "/api/v1/auth/verify_code", params: { email: user.email, code: "abc123" }
    assert_response :success
    assert json_response["token"].present?
    assert_equal user.id, json_response["user"]["id"]
    assert code.reload.used?
  end

  test "verify_code rejects a wrong code" do
    user = create_user
    AuthCode.create!(recipient: user.email, recipient_type: "email", context: "login", code: "ABC123")

    post "/api/v1/auth/verify_code", params: { email: user.email, code: "WRONG1" }
    assert_response :unauthorized
  end

  test "verify_code rejects an expired code" do
    user = create_user
    code = AuthCode.create!(recipient: user.email, recipient_type: "email", context: "login", code: "ABC123")
    # Derived, not restated: a hardcoded 20.minutes quietly stopped meaning
    # "expired" the moment EXPIRY moved from 15 to 30.
    code.update_column(:created_at, AuthCode::EXPIRY.ago - 1.minute)

    post "/api/v1/auth/verify_code", params: { email: user.email, code: "ABC123" }
    assert_response :unauthorized
  end

  test "verify_code rejects an already-used code" do
    user = create_user
    code = AuthCode.create!(recipient: user.email, recipient_type: "email", context: "login", code: "ABC123")
    code.mark_used!

    post "/api/v1/auth/verify_code", params: { email: user.email, code: "ABC123" }
    assert_response :unauthorized
  end

  test "verify_code rejects an email that was never sent a code" do
    post "/api/v1/auth/verify_code", params: { email: "nobody@test.com", code: "ABC123" }
    assert_response :unauthorized
  end

  test "verify_code creates the account on first login (signup)" do
    AuthCode.create!(recipient: "newcomer@test.com", recipient_type: "email", context: "login", code: "ABC123")

    assert_difference "User.count", 1 do
      post "/api/v1/auth/verify_code", params: { email: "Newcomer@Test.com", code: "ABC123" }
    end
    assert_response :success
    user = User.find_by(email: "newcomer@test.com")
    assert user, "user should be created with the normalized email"
    assert_nil user.name
    assert json_response["token"].present?
    assert_equal user.id, json_response["user"]["id"]
  end

  test "the returned JWT authenticates subsequent requests" do
    user = create_user
    AuthCode.create!(recipient: user.email, recipient_type: "email", context: "login", code: "ABC123")
    post "/api/v1/auth/verify_code", params: { email: user.email, code: "ABC123" }
    token = json_response["token"]

    get "/api/v1/users/me", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :success
  end

  test "request_code never leaks the code in its response body" do
    user = create_user
    post "/api/v1/auth/request_code", params: { email: user.email }
    code = AuthCode.for_recipient(user.email).order(:created_at).last.code

    assert_not_includes response.body, code
    assert_nil json_response["code"]
  end

  test "request_code rejects a malformed email" do
    assert_no_difference "AuthCode.count" do
      post "/api/v1/auth/request_code", params: { email: "" }
      assert_response :unprocessable_entity
      post "/api/v1/auth/request_code", params: { email: "not-an-email" }
      assert_response :unprocessable_entity
    end
  end

  test "verify_code stamps last_signin_at on success" do
    user = create_user
    AuthCode.create!(recipient: user.email, recipient_type: "email", context: "login", code: "ABC123")
    assert_nil user.last_signin_at

    post "/api/v1/auth/verify_code", params: { email: user.email, code: "ABC123" }
    assert_response :success
    assert_not_nil user.reload.last_signin_at
  end

  # ---------------------------------------------------------------- bind_wechat

  # JSAPI needs the payer's openid; a buyer who signed in by email has none.
  test "bind_wechat attaches an openid to the signed-in account" do
    ENV["NEXT_TOKEN"] = "tok"
    user = create_user

    post "/api/v1/auth/bind_wechat",
      params: { next_token: "tok", wechat_openid: "o_new", wechat_unionid: "u_new" },
      headers: auth_headers(user)

    assert_response :success
    assert_equal "o_new", user.reload.wechat_openid
    assert_equal "u_new", user.wechat_unionid
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  # The JWT says which account; only the frontend server may say what the
  # openid is, because it is the one that redeemed the code. Without this,
  # anyone could claim a stranger's openid and receive their next sign-in.
  test "bind_wechat refuses a caller without NEXT_TOKEN even with a valid session" do
    ENV["NEXT_TOKEN"] = "tok"
    user = create_user

    post "/api/v1/auth/bind_wechat",
      params: { wechat_openid: "o_new" }, headers: auth_headers(user)

    assert_response :unauthorized
    assert_nil user.reload.wechat_openid
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "bind_wechat requires a session, not just the shared secret" do
    ENV["NEXT_TOKEN"] = "tok"

    post "/api/v1/auth/bind_wechat", params: { next_token: "tok", wechat_openid: "o_new" }

    assert_response :unauthorized
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  # Merging in this direction would delete an account that may hold events and
  # orders — unlike bind_email's window, which only removes an empty, freshly
  # created WeChat account.
  test "bind_wechat refuses an identity that already belongs to someone else" do
    ENV["NEXT_TOKEN"] = "tok"
    create_user(wechat_openid: "o_taken")
    user = create_user

    post "/api/v1/auth/bind_wechat",
      params: { next_token: "tok", wechat_openid: "o_taken" }, headers: auth_headers(user)

    assert_response :unprocessable_entity
    assert_match "already linked", json_response["error"]
    assert_nil user.reload.wechat_openid
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "bind_wechat is idempotent for the identity's own owner" do
    ENV["NEXT_TOKEN"] = "tok"
    user = create_user(wechat_openid: "o_mine")

    post "/api/v1/auth/bind_wechat",
      params: { next_token: "tok", wechat_openid: "o_mine", wechat_unionid: "u_mine" },
      headers: auth_headers(user)

    assert_response :success
    assert_equal "o_mine", user.reload.wechat_openid
    # The unionid is new information and still fills the blank.
    assert_equal "u_mine", user.wechat_unionid
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  # A WeChat-first account already has one; re-pointing it at a different
  # person's identity is exactly what claimable? exists to prevent.
  test "bind_wechat never overwrites an openid the account already has" do
    ENV["NEXT_TOKEN"] = "tok"
    user = create_user(wechat_openid: "o_original")

    post "/api/v1/auth/bind_wechat",
      params: { next_token: "tok", wechat_openid: "o_other" }, headers: auth_headers(user)

    assert_response :success
    assert_equal "o_original", user.reload.wechat_openid
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "a correct code still works after a few (below-threshold) wrong attempts" do
    user = create_user
    AuthCode.create!(recipient: user.email, recipient_type: "email", context: "login", code: "ABC123")

    (AuthCode::MAX_ATTEMPTS - 1).times do
      post "/api/v1/auth/verify_code", params: { email: user.email, code: "WRONG1" }
      assert_response :unauthorized
    end

    post "/api/v1/auth/verify_code", params: { email: user.email, code: "ABC123" }
    assert_response :success
    assert json_response["token"].present?
  end

  test "verify_google signs in the email Google vouches for" do
    GoogleAuth.stub(:verified_email, "googler@test.com") do
      assert_difference "User.count", 1 do
        post "/api/v1/auth/verify_google", params: { access_token: "ya29.token" }
      end
    end
    assert_response :success
    assert json_response["token"].present?
    assert_equal "googler@test.com", User.last.email
  end

  test "verify_google rejects a token Google does not vouch for" do
    GoogleAuth.stub(:verified_email, nil) do
      assert_no_difference "User.count" do
        post "/api/v1/auth/verify_google", params: { access_token: "garbage" }
      end
    end
    assert_response :unauthorized
  end

  # The email branch trusted_signin used to have let any NEXT_TOKEN holder mint
  # a session for ANY address. It is gone — the endpoint is WeChat-only now —
  # and must not come back.
  test "trusted_signin no longer accepts an email identity" do
    ENV["NEXT_TOKEN"] = "test-token"
    assert_no_difference "User.count" do
      post "/api/v1/auth/trusted_signin", params: { next_token: "test-token", email: "victim@test.com" }
    end
    assert_response :unprocessable_entity
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "trusted_signin still signs in a WeChat identity with a valid NEXT_TOKEN" do
    ENV["NEXT_TOKEN"] = "test-token"
    assert_difference "User.count", 1 do
      post "/api/v1/auth/trusted_signin", params: { next_token: "test-token", wechat_openid: "oABC123" }
    end
    assert_response :success
    assert json_response["token"].present?
    assert_equal "oABC123", User.last.wechat_openid
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "trusted_signin rejects a wrong or missing NEXT_TOKEN" do
    ENV["NEXT_TOKEN"] = "test-token"
    post "/api/v1/auth/trusted_signin", params: { next_token: "wrong", wechat_openid: "oABC123" }
    assert_response :unauthorized
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  # ---------------------------------------------------- wechat nickname/avatar

  test "trusted_signin backfills nickname and avatar on a brand-new WeChat account" do
    ENV["NEXT_TOKEN"] = "test-token"
    post "/api/v1/auth/trusted_signin", params: {
      next_token: "test-token", wechat_openid: "oNEW1", wechat_nickname: "小明", wechat_avatar_url: "https://wx.qq.com/a.jpg"
    }
    assert_response :success
    user = User.last
    assert_equal "小明", user.nickname
    assert_equal "https://wx.qq.com/a.jpg", user.image_url
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "trusted_signin fills a blank nickname/avatar on an existing WeChat account, but never overwrites either" do
    ENV["NEXT_TOKEN"] = "test-token"
    user = create_user(wechat_openid: "oOLD1", nickname: nil, image_url: nil)

    post "/api/v1/auth/trusted_signin", params: {
      next_token: "test-token", wechat_openid: "oOLD1", wechat_nickname: "老王", wechat_avatar_url: "https://wx.qq.com/b.jpg"
    }
    assert_response :success
    user.reload
    assert_equal "老王", user.nickname
    assert_equal "https://wx.qq.com/b.jpg", user.image_url

    # A second sign-in with a DIFFERENT WeChat nickname/avatar must not
    # clobber what the person may have since set themselves.
    post "/api/v1/auth/trusted_signin", params: {
      next_token: "test-token", wechat_openid: "oOLD1", wechat_nickname: "换了个名", wechat_avatar_url: "https://wx.qq.com/c.jpg"
    }
    assert_response :success
    user.reload
    assert_equal "老王", user.nickname
    assert_equal "https://wx.qq.com/b.jpg", user.image_url
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "trusted_signin never overwrites a nickname/avatar the account already had before WeChat sign-in" do
    ENV["NEXT_TOKEN"] = "test-token"
    user = create_user(wechat_openid: "oOLD2", nickname: "Already Set", image_url: "https://cdn.sola.day/mine.jpg")

    post "/api/v1/auth/trusted_signin", params: {
      next_token: "test-token", wechat_openid: "oOLD2", wechat_nickname: "微信昵称", wechat_avatar_url: "https://wx.qq.com/d.jpg"
    }
    assert_response :success
    user.reload
    assert_equal "Already Set", user.nickname
    assert_equal "https://cdn.sola.day/mine.jpg", user.image_url
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "bind_wechat fills a blank nickname/avatar on the signed-in account" do
    ENV["NEXT_TOKEN"] = "tok"
    user = create_user(nickname: nil, image_url: nil)

    post "/api/v1/auth/bind_wechat",
      params: { next_token: "tok", wechat_openid: "o_new", wechat_nickname: "小红", wechat_avatar_url: "https://wx.qq.com/e.jpg" },
      headers: auth_headers(user)

    assert_response :success
    user.reload
    assert_equal "小红", user.nickname
    assert_equal "https://wx.qq.com/e.jpg", user.image_url
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "bind_wechat does not touch nickname/avatar when WeChat didn't send any" do
    ENV["NEXT_TOKEN"] = "tok"
    user = create_user(nickname: nil, image_url: nil)

    post "/api/v1/auth/bind_wechat",
      params: { next_token: "tok", wechat_openid: "o_new2" }, headers: auth_headers(user)

    assert_response :success
    user.reload
    assert_nil user.nickname
    assert_nil user.image_url
  ensure
    ENV.delete("NEXT_TOKEN")
  end
end
