class Api::V1::UsersController < Api::BaseController
  def show
    if params[:id] == "me" || params[:id] == current_user.id
      render json: UserBlueprint.render(current_user, view: :self)
    else
      # Other users: public fields only (no email).
      render json: UserBlueprint.render(User.find(params[:id]))
    end
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
