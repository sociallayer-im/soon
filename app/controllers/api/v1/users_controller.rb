class Api::V1::UsersController < Api::BaseController
  def show
    user = params[:id] == "me" ? current_user : User.find(params[:id])
    render json: UserBlueprint.render(user)
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def update
    if current_user.update(user_params)
      render json: UserBlueprint.render(current_user)
    else
      render_error(current_user.errors.full_messages.join(", "))
    end
  end

  private

  def user_params
    params.require(:user).permit(:name)
  end
end
