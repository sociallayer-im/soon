# A user's standing consent for one application. Separate from the tokens: the
# grant is what the user sees and manages at /oauth/grants, and it is what lets
# a returning user skip the consent screen for scopes they already approved.
class OauthGrant < ApplicationRecord
  belongs_to :user
  belongs_to :oauth_application, foreign_key: "application_id"

  validates :user_id, uniqueness: { scope: :application_id }

  def covers?(requested_scopes)
    (Array(requested_scopes) - scopes).empty?
  end

  def self.upsert_for(user:, application:, scopes:)
    grant = find_or_initialize_by(user: user, oauth_application: application)
    grant.scopes = (grant.scopes + Array(scopes)).uniq
    grant.save!
    grant
  end

  # Revoking consent must invalidate what that consent already produced,
  # otherwise "撤销授权" only stops future authorizations while the app keeps
  # calling the API with a token it already holds.
  def revoke!
    transaction do
      OauthAccessToken.where(user_id: user_id, application_id: application_id)
                      .where(revoked_at: nil).find_each(&:revoke!)
      OauthRefreshToken.where(user_id: user_id, application_id: application_id)
                       .where(revoked_at: nil).find_each(&:revoke!)
      destroy!
    end
  end
end
