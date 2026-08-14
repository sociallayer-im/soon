# Verifies a Google OAuth access token by presenting it to Google's userinfo
# endpoint and returns the verified email, or nil if Google doesn't vouch for
# it. This used to live in the Next.js frontend (behind the NEXT_TOKEN shared
# secret); verifying here means no secret exists that can mint a session for an
# arbitrary email.
#
# httpx for the same reasons as WeChatPayGateway: it neither asks for gzip it
# won't inflate nor silently routes through http_proxy from the environment.
class GoogleAuth
  USERINFO_URL = "https://www.googleapis.com/oauth2/v3/userinfo".freeze

  # Returns the normalized email string, or nil for anything short of Google
  # confirming a verified address — an expired/garbage token, a network
  # failure, or an account whose address Google itself hasn't verified
  # (signing that in would let someone claim an address they don't control).
  def self.verified_email(access_token)
    return nil if access_token.blank?

    response = HTTPX.get(USERINFO_URL, headers: {
      "Authorization" => "Bearer #{access_token}",
      "Accept" => "application/json"
    })
    return nil if response.is_a?(HTTPX::ErrorResponse) || response.status != 200

    info = JSON.parse(response.body.to_s)
    email = info["email"].to_s.strip.downcase
    return nil if email.blank? || info["email_verified"] == false

    email
  rescue JSON::ParserError
    nil
  end
end
