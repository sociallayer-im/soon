# Mints the OIDC id_token. RS256 rather than the HS256 the rest of soon uses
# for its own sessions: a relying party must be able to verify the signature
# without holding a secret we share with it, which is the entire point of
# publishing a JWKS.
#
# Deliberately distinct from JwtService — that mints sola's own session tokens
# with a symmetric key, and the two must never be interchangeable. An id_token
# is a statement ABOUT a user to a third party; it is not a credential for
# calling this API.
class OauthIdToken
  TTL = 1.hour

  def self.encode(user:, application:, scopes:, nonce: nil, auth_time: nil)
    now = Time.current
    claims = {
      iss: OauthConfig.issuer,
      sub: user.id,
      aud: application.client_id,
      iat: now.to_i,
      exp: (now + TTL).to_i,
      auth_time: (auth_time || now).to_i
    }
    claims[:nonce] = nonce if nonce.present?
    # Standard OIDC practice: the profile/email claims are also inlined so a
    # relying party can sign a user in with one round trip and never call
    # UserInfo. Only the flat, non-list claims — the group/event/badge/ticket
    # lists would bloat a token that travels in URLs and headers.
    claims.merge!(OauthClaims.new(user, scopes & %w[profile email phone wallet]).to_h.except(:sub))

    JWT.encode(claims, OauthConfig.private_key!, "RS256", kid: OauthConfig.key_id)
  end
end
