# Per-deployment OAuth identity. sola.day and juluo.xyz are two independent
# authorization servers — separate databases, separate client registries — so
# every value here has to come from the environment. Hardcoding an issuer is
# the same class of mistake as the CANONICAL_ORIGIN fallback that would have
# stamped international URLs into CN's share cards.
#
# The two deployments MUST hold different RSA keys. Sharing one would let a
# token minted by either issuer validate against the other's JWKS.
module OauthConfig
  Error = Class.new(StandardError)

  # https://api.sola.day — the issuer identifier third parties pin. It is the
  # API origin, not the web origin: that is where the discovery document and
  # the token endpoint actually live.
  def self.issuer
    ENV["OAUTH_ISSUER"].presence || "http://localhost:3000"
  end

  # Where the browser is sent to see the consent screen. The web app, not the
  # API — WEB_URL is already injected on both deployments.
  def self.consent_url
    base = ENV["WEB_URL"].presence || "http://localhost:4001"
    "#{base.chomp('/')}/oauth/authorize"
  end

  def self.private_key
    return @private_key if defined?(@private_key) && @private_key

    pem = ENV["OAUTH_RSA_PRIVATE_KEY"].presence ||
          Rails.application.credentials.dig(:oauth, :rsa_private_key)

    if pem.blank?
      # Outside production, mint a throwaway key per process. Relying parties
      # fetch the JWKS live and id_tokens live an hour, so an ephemeral key is
      # entirely usable in dev and test — and it means a developer never sees
      # the confusing half-working state where the discovery document promises
      # OIDC and the token endpoint quietly returns no id_token.
      #
      # In production the absence is deliberately NOT papered over: a key that
      # changed on every deploy would invalidate every id_token in flight, and
      # the token endpoint raises rather than issuing a response that a
      # standards-compliant client cannot use.
      return nil if Rails.env.production?
      return @private_key = OpenSSL::PKey::RSA.generate(2048)
    end

    @private_key = OpenSSL::PKey::RSA.new(normalize_pem(pem))
  rescue OpenSSL::PKey::RSAError => e
    Rails.logger.error("OauthConfig: OAUTH_RSA_PRIVATE_KEY is not a valid RSA key — #{e.message}")
    @private_key = nil
  end

  # A PEM is multi-line, and .env files and container environments are not.
  # Three spellings are therefore accepted, so nothing depends on how a
  # particular parser treats a quoted newline:
  #
  #   1. base64 of the whole PEM  — the recommended one, unambiguously one line
  #   2. the PEM with literal \n  — what a single-line .env entry usually becomes
  #   3. a real multi-line PEM    — what a local shell heredoc produces
  def self.normalize_pem(value)
    return value.gsub('\n', "\n") if value.include?("-----BEGIN")
    Base64.decode64(value)
  end
  private_class_method :normalize_pem

  def self.private_key!
    private_key || raise(Error, "OAUTH_RSA_PRIVATE_KEY is not configured")
  end

  def self.public_key = private_key&.public_key

  # Derived from the key itself, so it changes exactly when the key does and a
  # rotation needs no separate bookkeeping.
  def self.key_id
    return nil unless public_key
    @key_id ||= Digest::SHA256.hexdigest(public_key.to_der)[0, 16]
  end

  def self.jwks
    key = public_key
    return { keys: [] } unless key
    {
      keys: [ {
        kty: "RSA",
        use: "sig",
        alg: "RS256",
        kid: key_id,
        n: Base64.urlsafe_encode64(key.n.to_s(2), padding: false),
        e: Base64.urlsafe_encode64(key.e.to_s(2), padding: false)
      } ]
    }
  end

  # Test and development can run without a configured key; every OIDC flow that
  # needs an id_token then fails loudly at the point of use instead of at boot.
  def self.configured? = private_key.present?

  def self.reset!
    remove_instance_variable(:@private_key) if defined?(@private_key)
    remove_instance_variable(:@key_id) if defined?(@key_id)
  end
end
