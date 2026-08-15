# Shared by the OAuth credential models (authorization code, access token,
# refresh token). Each stores only a SHA-256 digest of the value it hands out,
# so a database dump yields nothing replayable — semi's implementation stored
# these in plaintext, which makes one dump equal to every live session.
#
# SHA-256 rather than BCrypt on purpose: these are 256-bit random strings, not
# passwords. There is no dictionary to slow down, and the lookup happens on
# every single API request.
module OauthDigestible
  extend ActiveSupport::Concern

  # The plaintext exists only on the instance that just generated it, and only
  # in memory. It is never re-derivable.
  attr_reader :plaintext_token

  class_methods do
    def digest(value) = Digest::SHA256.hexdigest(value.to_s)

    def find_by_token(value)
      return nil if value.blank?
      find_by(token_digest: digest(value))
    end
  end

  private

  def generate_token
    @plaintext_token = SecureRandom.hex(32)
    self.token_digest = self.class.digest(@plaintext_token)
  end
end
