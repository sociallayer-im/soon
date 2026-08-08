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
end
