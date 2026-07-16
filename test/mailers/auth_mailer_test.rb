require "test_helper"

class AuthMailerTest < ActionMailer::TestCase
  test "login_code renders the code, subject, recipient and multipart body" do
    mail = AuthMailer.login_code(email: "who@test.com", code: "ABC123")

    assert_equal ["who@test.com"], mail.to
    assert_equal "Your Social Layer sign-in code", mail.subject
    assert_equal "send@app.sola.day", mail.from.first

    assert_match "ABC123", mail.html_part.body.to_s
    assert_match "ABC123", mail.text_part.body.to_s
    # Expiry is derived from AuthCode::EXPIRY (15 minutes).
    assert_match "15 minutes", mail.html_part.body.to_s
  end
end
