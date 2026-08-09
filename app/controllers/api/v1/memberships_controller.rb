class Api::V1::MembershipsController < Api::BaseController
  # The member roster is public — group pages show members without login.
  skip_before_action :authenticate!, only: :index
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
  #
  # Two independently-authorized attributes: `role` (a group admin acting on
  # someone) and `admin_notification` (an admin's own mail preference). They're
  # checked separately and only the ones actually sent are written, so toggling
  # a notification setting doesn't require role-change rights and doesn't
  # accidentally clear the role.
  def update
    membership = @group.memberships.find(params[:id])
    attrs = params[:membership] || ActionController::Parameters.new
    writes = {}

    if attrs.key?(:admin_notification)
      raise Pundit::NotAuthorizedError unless can_set_admin_notification?(membership)
      writes[:admin_notification] = ActiveModel::Type::Boolean.new.cast(attrs[:admin_notification])
    end

    if attrs.key?(:role)
      new_role = attrs[:role]
      raise Pundit::NotAuthorizedError unless can_change_role?(membership.role, new_role)

      # Only an owner may grant the owner role or modify an existing owner's role,
      # so an admin can't self-promote to owner or demote the owner.
      if (new_role == "owner" || membership.role == "owner") && !group_owner?
        return render_error("only an owner can change owner-level roles", status: :forbidden)
      end
      writes[:role] = new_role
    end

    return render_error("nothing to update") if writes.empty?

    if membership.update(writes)
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
    @group = Group.resolve!(params[:group_id])
  end

  def can_remove?(membership)
    return true if membership.user_id == current_user.id  # self-leave
    return group_owner? if membership.role == "owner"     # only owners remove owners
    GroupPolicy.new(current_user, @group).manage?         # managers remove members/admins
  end

  # A direct group admin/owner may set any role. A parent-group manager may
  # only toggle the "manager" role specifically (promote to it or demote from
  # it) — see GroupPolicy#can_assign_manager?.
  def can_change_role?(current_role, new_role)
    policy = GroupPolicy.new(current_user, @group)
    return true if policy.manage?
    policy.can_assign_manager? && [current_role, new_role].include?("manager")
  end

  # The setting only governs mail sent to owners and managers, so it is only
  # settable on such a row — flipping it on a plain member would silently do
  # nothing and read back as if it had worked. Otherwise it's the member's own
  # preference; a group admin may also set it for another admin, which is how
  # the member roster's toggle works for an owner tidying up notifications.
  def can_set_admin_notification?(membership)
    return false unless %w[owner manager].include?(membership.role)

    membership.user_id == current_user.id || GroupPolicy.new(current_user, @group).manage?
  end

  def group_owner?
    current_user.memberships.exists?(group: @group, role: "owner")
  end
end
