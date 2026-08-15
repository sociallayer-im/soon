class OauthRefreshToken < ApplicationRecord
  include OauthDigestible

  belongs_to :user
  belongs_to :oauth_application, foreign_key: "application_id"
  belongs_to :oauth_access_token, foreign_key: "access_token_id"

  validates :token_digest, presence: true, uniqueness: true

  before_validation :generate_token, on: :create

  TTL = 30.days

  def self.issue(user:, application:, access_token:, family_id: nil)
    create!(
      user: user,
      oauth_application: application,
      oauth_access_token: access_token,
      family_id: family_id || SecureRandom.uuid,
      expires_at: TTL.from_now
    )
  end

  def active?
    revoked_at.nil? && expires_at > Time.current
  end

  def revoke!
    update!(revoked_at: Time.current) if revoked_at.nil?
  end

  # Rotation: each refresh burns this token and its access token and issues a
  # fresh pair carrying the same family_id. The expiry does NOT extend — the
  # family dies 30 days after the user consented, so a stolen refresh token
  # cannot be renewed indefinitely into a permanent session.
  # `scopes` narrows the new token (RFC 6749 §6 lets a client ask for less than
  # it was granted). It can only ever shrink — the caller checks that.
  def rotate!(scopes: nil)
    transaction do
      revoke!
      oauth_access_token.update!(revoked_at: Time.current)
      new_access = OauthAccessToken.issue(
        user: user, application: oauth_application, scopes: scopes || oauth_access_token.scopes
      )
      new_refresh = OauthRefreshToken.create!(
        user: user,
        oauth_application: oauth_application,
        oauth_access_token: new_access,
        family_id: family_id,
        expires_at: expires_at
      )
      [ new_access, new_refresh ]
    end
  end

  # Presenting an already-rotated refresh token means two parties hold the same
  # chain: the legitimate client and whoever copied it. There is no way to tell
  # which one is calling, so the entire family is destroyed and the user has to
  # re-consent. This is the standard RFC 6819 §5.2.2.3 response.
  def burn_family!
    self.class.where(family_id: family_id).where(revoked_at: nil).find_each(&:revoke!)
    OauthAccessToken.where(id: self.class.where(family_id: family_id).select(:access_token_id))
                    .where(revoked_at: nil)
                    .find_each(&:revoke!)
  end
end
