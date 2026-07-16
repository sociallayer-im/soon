class Api::V1::UsersController < Api::BaseController
  # Profile pages are public — auth is optional and only unlocks private fields.
  skip_before_action :authenticate!, only: :show
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

  def update
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
