class Api::V1::PlatformAdminsController < Api::BaseController
  before_action :require_platform_admin!

  # GET /api/v1/platform_admins
  def index
    scope = User.where("admin = TRUE OR ? = ANY(permissions)", "admin").order(:created_at)
    render_collection scope, blueprint: UserBlueprint, view: :profile
  end

  # POST /api/v1/platform_admins { user_id }
  # Sets users.admin only. The profile update allowlist cannot do this.
  def create
    user = User.resolve!(params[:user_id])
    user.update!(admin: true)
    render json: rendered(user), status: :created
  end

  # DELETE /api/v1/platform_admins/:id
  # Clears users.admin. Also drops the legacy permissions "admin" entry,
  # because that string would otherwise keep platform_admin? true.
  def destroy
    user = User.resolve!(params[:id])
    return render_error("cannot remove your own admin access") if user.id == current_user.id
    return render_error("cannot remove the last admin") unless User.where("admin = TRUE OR ? = ANY(permissions)", "admin").where.not(id: user.id).exists?

    user.update!(admin: false, permissions: Array(user.permissions) - [ "admin" ])
    head :no_content
  end

  private

  def require_platform_admin!
    render_error("forbidden", status: :forbidden) unless current_user.platform_admin?
  end

  def rendered(user)
    JSON.parse(UserBlueprint.render(user, view: :profile)).merge("admin" => user.admin?)
  end
end
