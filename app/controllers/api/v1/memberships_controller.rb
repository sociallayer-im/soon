class Api::V1::MembershipsController < Api::BaseController
  before_action :set_group

  # GET /api/v1/groups/:group_id/memberships
  def index
    render_collection @group.memberships.includes(:user), blueprint: MembershipBlueprint
  end

  # POST /api/v1/groups/:group_id/memberships
  #
  # Admin-only direct add — membership can otherwise only be gained via GroupInvite
  # (see Api::V1::GroupInvitesController), not self-service.
  def create
    authorize_group_admin!
    return if performed?

    user = User.find(params[:user_id])
    membership = @group.add_member(user.id, params[:role].presence || "member")
    render json: MembershipBlueprint.render(membership), status: :created
  rescue ActiveRecord::RecordNotFound
    render_not_found
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # PATCH /api/v1/groups/:group_id/memberships/:id
  def update
    membership = @group.memberships.find(params[:id])
    authorize_group_admin!
    return if performed?

    if membership.update(role: params.dig(:membership, :role))
      render json: MembershipBlueprint.render(membership)
    else
      render_error(membership.errors.full_messages.join(", "))
    end
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # DELETE /api/v1/groups/:group_id/memberships/:id
  def destroy
    membership = @group.memberships.find(params[:id])
    authorize_leave!(membership)
    return if performed?

    membership.destroy
    head :no_content
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  private

  def set_group
    @group = Group.find(params[:group_id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def authorize_group_admin!
    render json: { error: "Forbidden" }, status: :forbidden unless group_admin?(@group)
  end

  def authorize_leave!(membership)
    unless membership.user_id == current_user.id || group_admin?(@group)
      render json: { error: "Forbidden" }, status: :forbidden
    end
  end

  def group_admin?(group)
    current_user.memberships.exists?(group: group, role: %w[admin owner])
  end
end
