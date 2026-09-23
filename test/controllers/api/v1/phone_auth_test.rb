require "test_helper"

# SMS sign-in (CN only). SmsSender is not stubbed: with no Aliyun credentials in
# the test environment it logs the code and returns, which is the same code path
# as a successful send from the controller's point of view. The one test that
# needs a failure stubs it explicitly.
class Api::V1::PhoneAuthTest < ActionDispatch::IntegrationTest
  # Just past PHONE_CODE_INTERVAL, so a test that means to exercise something
  # other than the per-minute limit isn't tripped by it.
  PHONE_INTERVAL_SKIP = 31.seconds

  setup do
    ENV["PHONE_LOGIN_ENABLED"] = "true"
  end

  teardown do
    ENV.delete("PHONE_LOGIN_ENABLED")
  end

  # --- the deployment gate ------------------------------------------------

  test "both endpoints 404 when PHONE_LOGIN_ENABLED is unset" do
    ENV.delete("PHONE_LOGIN_ENABLED")

    assert_no_difference "AuthCode.count" do
      post "/api/v1/auth/request_phone_code", params: { phone: "13800138000" }
    end
    assert_response :not_found

    post "/api/v1/auth/verify_phone_code", params: { phone: "13800138000", code: "123456" }
    assert_response :not_found
  end

  # --- +86 only -----------------------------------------------------------

  test "rejects anything that is not a mainland mobile number" do
    [
      "12800138000",      # 128 is not an allocated mobile prefix
      "1380013800",       # 10 digits
      "138001380001",     # 12 digits
      "+14155552671",     # a US number, which the CN 签名 cannot deliver to
      "+8521234567",      # Hong Kong
      "not a phone",
      ""
    ].each do |input|
      assert_no_difference "AuthCode.count", "#{input.inspect} should have been rejected" do
        post "/api/v1/auth/request_phone_code", params: { phone: input }
      end
      assert_response :unprocessable_entity
    end
  end

  # The recipient is the AuthCode lookup key AND the uniquely-indexed
  # users.phone, so every spelling of one number has to land on one string —
  # otherwise a code requested as "138 0013 8000" cannot be verified as
  # "+8613800138000", and one person ends up with several accounts.
  test "every accepted spelling normalises to the same E.164 recipient" do
    [ "13800138000", "+8613800138000", "8613800138000", "138 0013 8000", "138-0013-8000", " +86 138 0013 8000 " ].each do |input|
      AuthCode.delete_all
      post "/api/v1/auth/request_phone_code", params: { phone: input }
      assert_response :success
      assert_equal "+8613800138000", AuthCode.last.recipient, "#{input.inspect} normalised wrong"
      assert_equal "phone", AuthCode.last.recipient_type
    end
  end

  # --- the happy path -----------------------------------------------------

  test "request then verify signs in, creating the account on first use" do
    post "/api/v1/auth/request_phone_code", params: { phone: "13900139000" }
    assert_response :success
    assert_equal "Code sent", json_response["message"]

    code = AuthCode.last
    assert_match(/\A\d{6}\z/, code.code)
    assert_equal Api::V1::AuthController::PHONE_LOGIN_CONTEXT, code.context

    assert_difference "User.count", 1 do
      post "/api/v1/auth/verify_phone_code", params: { phone: "13900139000", code: code.code }
    end
    assert_response :success
    assert json_response["token"].present?

    user = User.find(json_response["user"]["id"])
    assert_equal "+8613900139000", user.phone
    # No email and no name: the frontend reads the null name as "route to
    # /register", the same as a WeChat-first account.
    assert_nil user.email
    assert_nil json_response["user"]["name"]
    assert code.reload.used?
  end

  test "a second sign-in returns the same account, not a new one" do
    post "/api/v1/auth/request_phone_code", params: { phone: "13700137000" }
    post "/api/v1/auth/verify_phone_code", params: { phone: "13700137000", code: AuthCode.last.code }
    first_id = json_response["user"]["id"]

    travel PHONE_INTERVAL_SKIP do
      post "/api/v1/auth/request_phone_code", params: { phone: "+86 137 0013 7000" }
      assert_response :success
      post "/api/v1/auth/verify_phone_code", params: { phone: "8613700137000", code: AuthCode.last.code }
    end

    assert_response :success
    assert_equal first_id, json_response["user"]["id"]
  end

  # --- code hygiene, inherited from the email flow ------------------------

  test "a wrong code is rejected and dies after MAX_ATTEMPTS" do
    post "/api/v1/auth/request_phone_code", params: { phone: "13600136000" }
    code = AuthCode.last
    wrong = code.code == "000000" ? "111111" : "000000"

    AuthCode::MAX_ATTEMPTS.times do
      post "/api/v1/auth/verify_phone_code", params: { phone: "13600136000", code: wrong }
      assert_response :unauthorized
    end

    assert code.reload.used?
    post "/api/v1/auth/verify_phone_code", params: { phone: "13600136000", code: code.code }
    assert_response :unauthorized
  end

  test "requesting a new code invalidates the previous one" do
    post "/api/v1/auth/request_phone_code", params: { phone: "13500135000" }
    first = AuthCode.last

    travel PHONE_INTERVAL_SKIP do
      post "/api/v1/auth/request_phone_code", params: { phone: "13500135000" }
      assert_response :success
    end

    assert first.reload.used?
    post "/api/v1/auth/verify_phone_code", params: { phone: "13500135000", code: first.code }
    assert_response :unauthorized
  end

  # The whole point of separate contexts: the digits are the same six, so
  # without it a texted code would sign in whoever holds the matching email.
  test "a phone code cannot be redeemed as an email code, or the reverse" do
    user = create_user
    post "/api/v1/auth/request_code", params: { email: user.email }
    email_code = AuthCode.last

    post "/api/v1/auth/verify_phone_code", params: { phone: "13400134000", code: email_code.code }
    assert_response :unauthorized

    post "/api/v1/auth/request_phone_code", params: { phone: "13400134000" }
    phone_code = AuthCode.last
    post "/api/v1/auth/verify_code", params: { email: user.email, code: phone_code.code }
    assert_response :unauthorized
  end

  # --- rate limiting ------------------------------------------------------

  test "a second request within the interval is refused" do
    post "/api/v1/auth/request_phone_code", params: { phone: "13300133000" }
    assert_response :success

    assert_no_difference "AuthCode.count" do
      post "/api/v1/auth/request_phone_code", params: { phone: "13300133000" }
    end
    assert_response :too_many_requests
    # The client reads this to send the person on to the code screen.
    assert_equal "SMS_COOLDOWN", JSON.parse(response.body)["code"]
  end

  test "the hourly cap holds even when each request waits out the interval" do
    phone = "13200132000"
    Api::V1::AuthController::PHONE_CODE_HOURLY_LIMIT.times do |i|
      travel(i * PHONE_INTERVAL_SKIP) do
        post "/api/v1/auth/request_phone_code", params: { phone: phone }
        assert_response :success
      end
    end

    travel(Api::V1::AuthController::PHONE_CODE_HOURLY_LIMIT * PHONE_INTERVAL_SKIP) do
      assert_no_difference "AuthCode.count" do
        post "/api/v1/auth/request_phone_code", params: { phone: phone }
      end
      assert_response :too_many_requests
    end

    # …and lifts once the window has passed.
    travel 2.hours do
      post "/api/v1/auth/request_phone_code", params: { phone: phone }
      assert_response :success
    end
  end

  # Rate limiting counts codes minted, and requesting one marks the previous
  # used — so a limiter written against AuthCode.active would see a single row
  # however many texts had gone out.
  test "invalidated codes still count toward the hourly cap" do
    phone = "13100131000"
    Api::V1::AuthController::PHONE_CODE_HOURLY_LIMIT.times do |i|
      travel(i * PHONE_INTERVAL_SKIP) { post "/api/v1/auth/request_phone_code", params: { phone: phone } }
    end

    assert_equal 1, AuthCode.active.for_recipient("+8613100131000").count
    assert_equal Api::V1::AuthController::PHONE_CODE_HOURLY_LIMIT,
      AuthCode.for_recipient("+8613100131000").count
  end

  # --- binding a phone to a WeChat account --------------------------------

  test "a WeChat account binds a phone and keeps its identity" do
    user = User.create!(wechat_openid: "openid_#{unique_suffix}")

    post "/api/v1/auth/request_phone_code", params: { phone: "13800138001", context: "bind_phone" }
    assert_response :success
    assert_equal Api::V1::AuthController::BIND_PHONE_CONTEXT, AuthCode.last.context

    post "/api/v1/auth/bind_phone",
      params: { phone: "13800138001", code: AuthCode.last.code }, headers: auth_headers(user)
    assert_response :success
    assert_equal "+8613800138001", user.reload.phone
    assert_equal "+8613800138001", json_response["phone"]
    assert json_response["wechat"], "the self view should report this as a WeChat account"
  end

  test "bind_phone requires a session" do
    post "/api/v1/auth/request_phone_code", params: { phone: "13800138002", context: "bind_phone" }
    post "/api/v1/auth/bind_phone", params: { phone: "13800138002", code: AuthCode.last.code }
    assert_response :unauthorized
  end

  # The contexts have to hold in this direction too, or the code texted for a
  # sign-in becomes a way to staple someone else's number onto your account.
  test "a login code cannot be redeemed as a bind code" do
    user = User.create!(wechat_openid: "openid_#{unique_suffix}")
    post "/api/v1/auth/request_phone_code", params: { phone: "13800138003" }

    post "/api/v1/auth/bind_phone",
      params: { phone: "13800138003", code: AuthCode.last.code }, headers: auth_headers(user)
    assert_response :unauthorized
    assert_nil user.reload.phone
  end

  test "a phone can only be bound once" do
    user = User.create!(wechat_openid: "openid_#{unique_suffix}", phone: "+8613800138004")

    post "/api/v1/auth/request_phone_code", params: { phone: "13800138005", context: "bind_phone" }
    post "/api/v1/auth/bind_phone",
      params: { phone: "13800138005", code: AuthCode.last.code }, headers: auth_headers(user)

    assert_response :unprocessable_entity
    assert_equal "+8613800138004", user.reload.phone
  end

  # Binding is a REQUIRED step, so a number that already signed itself in must
  # not dead-end the only way forward — it merges, on exactly the terms
  # #mergeable? allows for email.
  test "binding a number that already has an account merges into it" do
    post "/api/v1/auth/request_phone_code", params: { phone: "13800138006" }
    post "/api/v1/auth/verify_phone_code", params: { phone: "13800138006", code: AuthCode.last.code }
    original = User.find(json_response["user"]["id"])
    original.update!(name: "phone-first-user")

    wechat = User.create!(wechat_openid: "openid_#{unique_suffix}")

    travel PHONE_INTERVAL_SKIP do
      post "/api/v1/auth/request_phone_code", params: { phone: "13800138006", context: "bind_phone" }
      assert_difference "User.count", -1 do
        post "/api/v1/auth/bind_phone",
          params: { phone: "13800138006", code: AuthCode.last.code }, headers: auth_headers(wechat)
      end
    end

    assert_response :success
    # A merge makes the caller a DIFFERENT account, so it answers with a fresh
    # token rather than a profile — the one it sent authenticates nothing now.
    assert json_response["merged"]
    assert_equal original.id, json_response["user"]["id"]
    assert_nil User.find_by(id: wechat.id)
    assert_equal wechat.wechat_openid, original.reload.wechat_openid
  end

  test "a registered WeChat account cannot take over an in-use number" do
    post "/api/v1/auth/request_phone_code", params: { phone: "13800138007" }
    post "/api/v1/auth/verify_phone_code", params: { phone: "13800138007", code: AuthCode.last.code }

    # A name means the account is real, which closes the merge window.
    wechat = User.create!(wechat_openid: "openid_#{unique_suffix}", name: "established-one")

    travel PHONE_INTERVAL_SKIP do
      post "/api/v1/auth/request_phone_code", params: { phone: "13800138007", context: "bind_phone" }
      assert_no_difference "User.count" do
        post "/api/v1/auth/bind_phone",
          params: { phone: "13800138007", code: AuthCode.last.code }, headers: auth_headers(wechat)
      end
    end

    assert_response :unprocessable_entity
    assert_nil wechat.reload.phone
  end

  # The phone step runs BEFORE the email step, so by the time an email merge
  # happens the WeChat account being destroyed may hold a verified number.
  test "an email merge carries the phone bound in the earlier step" do
    target = create_user
    wechat = User.create!(wechat_openid: "openid_#{unique_suffix}")

    post "/api/v1/auth/request_phone_code", params: { phone: "13800138008", context: "bind_phone" }
    post "/api/v1/auth/bind_phone",
      params: { phone: "13800138008", code: AuthCode.last.code }, headers: auth_headers(wechat)
    assert_response :success

    post "/api/v1/auth/request_code", params: { email: target.email, context: "bind_email" }
    post "/api/v1/auth/bind_email",
      params: { email: target.email, code: AuthCode.last.code }, headers: auth_headers(wechat)
    assert_response :success
    assert json_response["merged"]

    assert_equal "+8613800138008", target.reload.phone, "the verified number was dropped by the merge"
  end

  # --- phone before username ----------------------------------------------

  # Enforced server-side, not just by the frontend's redirect chain: /register
  # is reachable by typing it, and a name set early closes the merge window for
  # a bind step that cannot be skipped.
  test "a WeChat account cannot take a username before binding a phone" do
    wechat = User.create!(wechat_openid: "openid_#{unique_suffix}")

    patch "/api/v1/users/#{wechat.id}",
      params: { user: { name: "too-early" } }, headers: auth_headers(wechat)

    assert_response :unprocessable_entity
    assert_nil wechat.reload.name
  end

  test "the same account can take a username once the phone is bound" do
    wechat = User.create!(wechat_openid: "openid_#{unique_suffix}")

    post "/api/v1/auth/request_phone_code", params: { phone: "13800138010", context: "bind_phone" }
    post "/api/v1/auth/bind_phone",
      params: { phone: "13800138010", code: AuthCode.last.code }, headers: auth_headers(wechat)
    assert_response :success

    patch "/api/v1/users/#{wechat.id}",
      params: { user: { name: "now-allowed" } }, headers: auth_headers(wechat)

    assert_response :success
    assert_equal "now-allowed", wechat.reload.name
  end

  # The rule is about WeChat's guarantee that the user is a mainland one with a
  # number. An email or wallet account carries no such guarantee and must not be
  # caught by it.
  test "an email account is unaffected by the phone requirement" do
    user = User.create!(email: "nophone#{unique_suffix}@test.com")

    patch "/api/v1/users/#{user.id}",
      params: { user: { name: "email-#{unique_suffix}" } }, headers: auth_headers(user)

    assert_response :success
    assert_not_nil user.reload.name
  end

  test "editing other fields still works while the phone is outstanding" do
    wechat = User.create!(wechat_openid: "openid_#{unique_suffix}")

    patch "/api/v1/users/#{wechat.id}",
      params: { user: { bio: "still me" } }, headers: auth_headers(wechat)

    assert_response :success
    assert_equal "still me", wechat.reload.bio
  end

  # Once a name exists the merge window is shut regardless, so a later edit has
  # nothing left to protect and refusing it would only break renaming.
  test "an already-named WeChat account can still edit its name" do
    wechat = User.create!(wechat_openid: "openid_#{unique_suffix}", name: "named-already")

    patch "/api/v1/users/#{wechat.id}",
      params: { user: { name: "renamed-ok" } }, headers: auth_headers(wechat)

    assert_response :success
    assert_equal "renamed-ok", wechat.reload.name
  end

  test "the requirement does not exist on a deployment without phone sign-in" do
    ENV.delete("PHONE_LOGIN_ENABLED")
    wechat = User.create!(wechat_openid: "openid_#{unique_suffix}")

    patch "/api/v1/users/#{wechat.id}",
      params: { user: { name: "sg-#{unique_suffix}" } }, headers: auth_headers(wechat)

    assert_response :success
    assert_not_nil wechat.reload.name
  end

  # --- gateway failure ----------------------------------------------------

  test "a gateway rejection reaches the caller instead of a silent success" do
    SmsSender.stub :send_login_code, ->(*, **) { raise SmsSender::Error, "isv.BUSINESS_LIMIT_CONTROL: 触发天级流控" } do
      post "/api/v1/auth/request_phone_code", params: { phone: "13000130000" }
    end

    assert_response :bad_gateway
    assert_match(/BUSINESS_LIMIT_CONTROL/, json_response["error"])
  end

  # A number that has just been texted must not be locked out by a failure that
  # happened after the message may already have gone out.
  test "the code minted before a gateway failure is still usable" do
    SmsSender.stub :send_login_code, ->(*, **) { raise SmsSender::Error, "boom" } do
      post "/api/v1/auth/request_phone_code", params: { phone: "13000130001" }
    end
    assert_response :bad_gateway

    post "/api/v1/auth/verify_phone_code", params: { phone: "13000130001", code: AuthCode.last.code }
    assert_response :success
  end
end
