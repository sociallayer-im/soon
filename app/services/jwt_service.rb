class JwtService
  Error = Class.new(StandardError)

  SECRET = ENV.fetch("JWT_SECRET") { Rails.application.secret_key_base }
  ALGORITHM = "HS256"
  TTL = 30.days

  def self.encode(payload, exp: TTL.from_now)
    JWT.encode(payload.merge(exp: exp.to_i), SECRET, ALGORITHM)
  end

  def self.decode(token)
    raise Error, "Missing token" if token.blank?
    JWT.decode(token, SECRET, true, algorithm: ALGORITHM).first
  rescue JWT::DecodeError => e
    raise Error, e.message
  end
end
