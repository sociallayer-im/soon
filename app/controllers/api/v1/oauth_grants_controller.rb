# "Which apps can see my data, and stop that one." Scoped to current_user with
# no parameter that could widen it — a grant list is a map of one person's
# third-party relationships and is nobody else's business.
class Api::V1::OauthGrantsController < Api::BaseController
  def index
    grants = OauthGrant.where(user: current_user)
                       .includes(oauth_application: %i[owner group])
                       .order(created_at: :desc)
    render json: OauthGrantBlueprint.render_as_hash(grants)
  end

  def destroy
    grant = OauthGrant.find_by!(id: params[:id], user_id: current_user.id)
    # Also revokes the tokens the consent produced — see OauthGrant#revoke!.
    grant.revoke!
    render json: { result: "ok" }
  end
end
