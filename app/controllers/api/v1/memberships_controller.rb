class Api::V1::MembershipsController < Api::BaseController
  before_action :set_group

  # GET /api/v1/groups/:group_id/memberships
  def index
    authorize @group, :members?
    render_collection @group.memberships.includes(:user), blueprint: MembershipBlueprint
  end

  # POST /api/v1/groups/:group_id/memberships
  #
  # Admin-only direct add — membership can otherwise only be gained via GroupInvite
  # (see Api::V1::GroupInvitesController), not self-service.
  def create
    authorize @group, :manage?
    role = params[:role].presence || "member"
    return render_error("only an owner can grant the owner role", status: :forbidden) if role == "owner" && !group_owner?

    user = User.find(params[:user_id])
    membership = @group.add_member(user.id, role)
    render json: MembershipBlueprint.render(membership), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # PATCH /api/v1/groups/:group_id/memberships/:id
  def update
    authorize @group, :manage?
    membership = @group.memberships.find(params[:id])
    new_role = params.dig(:membership, :role)

    # Only an owner may grant the owner role or modify an existing owner's role,
    # so an admin can't self-promote to owner or demote the owner.
    if (new_role == "owner" || membership.role == "owner") && !group_owner?
      return render_error("only an owner can change owner-level roles", status: :forbidden)
    end

    if membership.update(role: new_role)
      render json: MembershipBlueprint.render(membership)
    else
      render_error(membership.errors.full_messages.join(", "))
    end
  end

  # DELETE /api/v1/groups/:group_id/memberships/:id
  def destroy
    membership = @group.memberships.find(params[:id])
    raise Pundit::NotAuthorizedError unless can_remove?(membership)

    if membership.role == "owner" && @group.memberships.where(role: "owner").count <= 1
      return render_error("cannot remove the last owner of a group")
    end

    membership.destroy # counter_cache decrements memberships_count
    head :no_content
  end

  private

  def set_group
    @group = Group.find(params[:group_id])
  end

  def can_remove?(membership)
    return true if membership.user_id == current_user.id  # self-leave
    return group_owner? if membership.role == "owner"     # only owners remove owners
    GroupPolicy.new(current_user, @group).manage?         # managers remove members/admins
  end

  def group_owner?
    current_user.memberships.exists?(group: @group, role: "owner")
  end
end
