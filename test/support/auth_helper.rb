module AuthHelper
  def auth_headers(user)
    { "Authorization" => "Bearer #{JwtService.encode({ "user_id" => user.id })}" }
  end

  def json_response
    JSON.parse(response.body)
  end
end
