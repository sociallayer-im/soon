class OauthAuthorizationCode < ApplicationRecord
  include OauthDigestible

  belongs_to :user
  belongs_to :oauth_application, foreign_key: "application_id"

  validates :token_digest, presence: true, uniqueness: true
  validates :code_challenge, presence: true
  validates :redirect_uri, presence: true
  validates :code_challenge_method, inclusion: { in: %w[S256] }

  before_validation :generate_token, on: :create
  before_validation :set_expiry, on: :create

  scope :unused, -> { where(used_at: nil).where("expires_at > ?", Time.current) }

  # Long enough for a browser redirect and a server-side exchange, short enough
  # that a code sitting in a proxy log or Referer header is already dead.
  TTL = 60.seconds

  def self.issue(user:, application:, scopes:, redirect_uri:, code_challenge:, nonce: nil)
    create!(
      user: user,
      oauth_application: application,
      scopes: scopes,
      redirect_uri: redirect_uri,
      code_challenge: code_challenge,
      nonce: nonce
    )
  end

  # RFC 7636: the client proves it is the same party that started the flow by
  # revealing the verifier whose SHA-256 it committed to up front. Without this,
  # an authorization code intercepted at the redirect (a malicious app
  # registered for the same custom scheme, a shared browser, a leaked log) is
  # enough to mint tokens.
  def pkce_valid?(verifier)
    return false if verifier.blank?
    expected = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    ActiveSupport::SecurityUtils.secure_compare(expected, code_challenge.to_s)
  end

  private

  def set_expiry
    self.expires_at ||= TTL.from_now
  end
end
