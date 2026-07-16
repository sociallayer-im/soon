class Api::V1::AuthController < ActionController::API
  CONTEXT = "login".freeze

  # POST /api/v1/auth/request_code
  def request_code
    user = User.find_by(email: params[:email])
    if user
      # Only the latest code stays valid — invalidate any prior unused login codes
      # so an attacker can't stack many concurrently-guessable codes.
      AuthCode.active.for_recipient(user.email).for_context(CONTEXT).update_all(used_at: Time.current)
      code = AuthCode.create!(
        recipient: user.email, recipient_type: "email", context: CONTEXT,
        code: SecureRandom.alphanumeric(6).upcase
      )
      # Sent synchronously so a delivery failure surfaces on this request.
      AuthMailer.login_code(email: user.email, code: code.code).deliver_now
    end

    # Uniform response whether or not the email exists — no account enumeration.
    render json: { message: "Code sent" }
  end

  # POST /api/v1/auth/verify_code
  def verify_code
    user = User.find_by(email: params[:email])
    code = user && AuthCode.active.for_recipient(user.email).for_context(CONTEXT).order(created_at: :desc).first
    return render json: { error: "Invalid or expired code" }, status: :unauthorized unless code

    unless ActiveSupport::SecurityUtils.secure_compare(code.code, params[:code].to_s.upcase)
      code.register_failed_attempt!
      return render json: { error: "Invalid or expired code" }, status: :unauthorized
    end

    code.mark_used!
    user.update(last_signin_at: Time.current)
    token = JwtService.encode({ "user_id" => user.id })
    render json: { token: token, user: { id: user.id, email: user.email, name: user.name } }
  end
end
