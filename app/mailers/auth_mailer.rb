class AuthMailer < ApplicationMailer
  # The one-time sign-in / verification code. Sent synchronously by the caller
  # (deliver_now) so a delivery failure surfaces on the request that asked for it.
  def login_code(email:, code:)
    @code = code
    @expiry_minutes = (AuthCode::EXPIRY / 60).to_i
    mail(to: email, subject: "Your #{BRAND_NAME} sign-in code")
  end
end
