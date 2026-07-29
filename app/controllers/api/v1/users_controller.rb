class Api::V1::UsersController < Api::BaseController
  # Profile pages are public — auth is optional and only unlocks private fields.
  skip_before_action :authenticate!, only: %i[show groups]
  before_action :authenticate_optional!, only: :show

  # :id accepts "me", a TSID, or a username (User.resolve!).
  def show
    if params[:id] == "me"
      return render json: { error: "Unauthorized" }, status: :unauthorized unless current_user
      return render json: UserBlueprint.render(current_user, view: :self)
    end

    user = User.resolve!(params[:id])
    # Own record gets private fields (email); everyone else the public profile.
    view = user.id == current_user&.id ? :self : :profile
    render json: UserBlueprint.render(user, view: view)
  end

  # GET /api/v1/users/:id/groups?role=owner,admin — a user's public group
  # memberships (their profile page's "communities"), optionally by role.
  def groups
    user = User.resolve!(params[:id])
    scope = user.memberships.joins(:group).includes(:group).where(active: true, groups: { active: true })
    scope = scope.where(role: params[:role].to_s.split(",")) if params[:role].present?
    render json: MembershipBlueprint.render(scope.order(:created_at), view: :with_group)
  end

  def update
    # The model allows a nil name (wallet users pre-registration), but you
    # can't blank out a name you already picked — it's your public identity.
    if params[:user]&.key?(:name) && params[:user][:name].blank?
      return render_error("name can't be blank")
    end

    if current_user.update(user_params)
      render json: UserBlueprint.render(current_user, view: :self)
    else
      render_error(current_user.errors.full_messages.join(", "))
    end
  end

  private

  # email is intentionally excluded — it's the login identity, not updatable here.
  def user_params
    params.require(:user).permit(:name, :nickname, :bio, :image_url)
  end
end
