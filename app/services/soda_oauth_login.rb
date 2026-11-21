class SodaOauthLogin
  ISSUER = "https://api.juluo.xyz".freeze
  AUTHORIZE = "https://soda.fan/oauth/authorize".freeze
  REDIRECTS = %w[https://web.soda.fan/login/soda/callback https://auth.soda.fan/login/soda/callback].freeze
  class Unavailable < StandardError; end
  class InvalidCode < StandardError; end

  def self.configuration
    id = ENV["SODA_OAUTH_CLIENT_ID"].presence
    return unless id && ENV["SODA_OAUTH_CLIENT_SECRET"].present?
    { client_id: id, authorization_url: AUTHORIZE }
  end

  def self.identity(code:, verifier:, redirect_uri:)
    config = configuration || raise(Unavailable)
    unless REDIRECTS.include?(redirect_uri) && code.match?(/\A[A-Za-z0-9._~-]{1,512}\z/) &&
        verifier.match?(/\A[A-Za-z0-9._~-]{43,128}\z/)
      raise InvalidCode
    end

    client = HTTPX.with(timeout: { operation_timeout: 8 })
    token = parse(client.post("#{ISSUER}/api/v1/oauth/token", form: {
      grant_type: "authorization_code", client_id: config.fetch(:client_id),
      client_secret: ENV.fetch("SODA_OAUTH_CLIENT_SECRET"), code: code,
      redirect_uri: redirect_uri, code_verifier: verifier
    }))
    access_token = token["access_token"]
    raise InvalidCode unless access_token.is_a?(String) && access_token.match?(/\A[A-Za-z0-9._~-]{1,2048}\z/)
    profile = parse(client.get("#{ISSUER}/api/v1/oauth/userinfo", headers: { "authorization" => "Bearer #{access_token}" }))
    subject = profile["sub"]
    raise InvalidCode unless subject.is_a?(String) && subject.present? && subject.bytesize <= 255
    { issuer: ISSUER, subject: subject, nickname: profile["name"].to_s.first(60).presence }
  end

  def self.parse(response)
    raise Unavailable if response.is_a?(HTTPX::ErrorResponse) || response.status >= 500
    raise InvalidCode unless response.status == 200
    data = JSON.parse(response.body.to_s)
    raise InvalidCode unless data.is_a?(Hash)
    data
  rescue JSON::ParserError
    raise Unavailable
  end
  private_class_method :parse
end
