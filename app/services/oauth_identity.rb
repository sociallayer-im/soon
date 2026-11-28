# A minimal live identity response, intentionally separate from broad UserInfo
# lists. Never grants network access or exposes contact/payment credentials.
class OauthIdentity
  def initialize(access_token)
    @token = access_token
  end

  def to_h(group_id: nil)
    user = @token.user
    result = {
      issuer: OauthConfig.issuer,
      subject: user.id,
      expires_at: @token.expires_at.to_i,
      scope: @token.scopes.join(" ")
    }
    if @token.scope?("profile")
      result.merge!(username: user.name, nickname: user.nickname, avatar_url: user.image_url)
    end
    if group_id
      # Exact indexed lookup, not UserInfo's truncated membership list. Both
      # the boolean and temporal validity matter; neither implies the other.
      membership = user.memberships.active.where(group_id: group_id)
        .joins(:group).where(groups: {active: true, review_status: "approved"})
        .where(role: %w[owner manager member]).first
      result[:group] = {
        id: group_id, member: membership.present?, role: membership&.role,
        expires_at: membership&.expires_at&.to_i
      }
    end
    result
  end
end
