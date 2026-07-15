class Api::V1::AuthController < ActionController::API
  # POST /api/v1/auth/request_code
  def request_code
    user = User.find_by(email: params[:email])
    return render json: { error: "Email not found" }, status: :not_found unless user

    code = AuthCode.create!(
      recipient: user.email,
      recipient_type: "email",
      context: "login",
      code: SecureRandom.alphanumeric(6).upcase
    )

    # TODO: deliver code via email/SMS
    render json: { message: "Code sent" }
  end

  # POST /api/v1/auth/verify_code
  def verify_code
    user = User.find_by(email: params[:email])
    return render json: { error: "Invalid credentials" }, status: :unauthorized unless user

    auth_code = AuthCode.active.for_recipient(user.email).find_by(code: params[:code]&.upcase)
    return render json: { error: "Invalid or expired code" }, status: :unauthorized unless auth_code

    auth_code.mark_used!
    token = JwtService.encode({ "user_id" => user.id })
    render json: { token: token, user: { id: user.id, email: user.email, name: user.name } }
  end
end
