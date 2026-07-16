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

  test "request_code returns a uniform response for an unknown email (no enumeration) and mints no code" do
    assert_no_difference "AuthCode.count" do
      post "/api/v1/auth/request_code", params: { email: "nobody@test.com" }
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
    code.update_column(:created_at, 20.minutes.ago)

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

  test "verify_code rejects unknown email" do
    post "/api/v1/auth/verify_code", params: { email: "nobody@test.com", code: "ABC123" }
    assert_response :unauthorized
  end

  test "the returned JWT authenticates subsequent requests" do
    user = create_user
    AuthCode.create!(recipient: user.email, recipient_type: "email", context: "login", code: "ABC123")
    post "/api/v1/auth/verify_code", params: { email: user.email, code: "ABC123" }
    token = json_response["token"]

    get "/api/v1/users/me", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :success
  end
end
