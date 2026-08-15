# The two OIDC documents that the spec pins to the root of the issuer origin,
# plus the standards-compliant browser entry point to the authorization
# endpoint. Everything else lives under /api/v1/oauth.
class WellKnownController < Api::BaseController
  skip_before_action :authenticate!

  # GET /.well-known/openid-configuration
  def openid_configuration
    issuer = OauthConfig.issuer
    render json: {
      issuer: issuer,
      # The browser-facing endpoint, not the JSON one — this is the URL a
      # client library will navigate the user to.
      authorization_endpoint: "#{issuer}/oauth/authorize",
      token_endpoint: "#{issuer}/api/v1/oauth/token",
      userinfo_endpoint: "#{issuer}/api/v1/oauth/userinfo",
      revocation_endpoint: "#{issuer}/api/v1/oauth/revoke",
      jwks_uri: "#{issuer}/.well-known/jwks.json",
      response_types_supported: [ "code" ],
      grant_types_supported: [ "authorization_code", "refresh_token" ],
      subject_types_supported: [ "public" ],
      id_token_signing_alg_values_supported: [ "RS256" ],
      scopes_supported: OauthApplication::VALID_SCOPES,
      claims_supported: %w[sub iss aud exp iat nonce preferred_username name picture email email_verified],
      token_endpoint_auth_methods_supported: %w[client_secret_basic client_secret_post none],
      code_challenge_methods_supported: [ "S256" ]
    }
  end

  # GET /.well-known/jwks.json
  def jwks
    expires_in 1.hour, public: true
    render json: OauthConfig.jwks
  end

  # GET /oauth/authorize
  #
  # The bridge that lets a generic OIDC client library work unmodified: it
  # navigates the browser here, and here bounces to the consent page in the web
  # app carrying the query string through. Without this a relying party would
  # have to know that sola's consent screen lives on a different origin than
  # its issuer, which no library supports.
  #
  # No validation happens here on purpose — the consent page immediately calls
  # GET /api/v1/oauth/authorize, which validates and renders the error. Doing
  # it twice would mean two places that decide what a valid request is.
  def authorize_redirect
    redirect_to("#{OauthConfig.consent_url}?#{request.query_string}", allow_other_host: true, status: :found)
  end
end
