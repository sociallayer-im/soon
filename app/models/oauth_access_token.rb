class OauthAccessToken < ApplicationRecord
  include OauthDigestible

  belongs_to :user
  belongs_to :oauth_application, foreign_key: "application_id"
  has_one :oauth_refresh_token, foreign_key: "access_token_id", dependent: :destroy

  validates :token_digest, presence: true, uniqueness: true

  before_validation :generate_token, on: :create

  # One hour, against semi's ten years. These are opaque strings looked up in
  # the database on every request, so a short life costs nothing — and it means
  # a leaked token is a one-hour problem rather than a decade-long one that
  # depends on someone noticing and revoking it.
  TTL = 1.hour

  def self.issue(user:, application:, scopes:)
    create!(user: user, oauth_application: application, scopes: scopes, expires_at: TTL.from_now)
  end

  def active?
    revoked_at.nil? && expires_at > Time.current
  end

  def revoke!
    update!(revoked_at: Time.current) if revoked_at.nil?
    oauth_refresh_token&.revoke!
  end

  def scope?(scope) = scopes.include?(scope)
end
