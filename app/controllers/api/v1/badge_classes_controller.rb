class Api::V1::BadgeClassesController < Api::BaseController
  before_action :set_badge_class, only: %i[show invites]

  # POST /api/v1/badge_classes
  def create
    if params[:group_id].present?
      group = Group.find(params[:group_id])
      authorize group, :manage?, policy_class: GroupPolicy
    end

    badge_class = BadgeClass.new(badge_class_params.merge(creator: current_user))
    if badge_class.save
      render json: BadgeClassBlueprint.render(badge_class), status: :created
    else
      render_error(badge_class.errors.full_messages.join(", "))
    end
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /api/v1/badge_classes/:id
  def show
    render json: BadgeClassBlueprint.render(@badge_class)
  end

  # GET /api/v1/badge_classes
  def index
    scope = BadgeClass.all
    scope = scope.where(group_id: params[:group_id]) if params[:group_id].present?
    scope = scope.where(badge_type: params[:badge_type]) if params[:badge_type].present?
    scope = scope.joins(:creator).where(users: { handle: params[:creator_handle] }) if params[:creator_handle].present?
    scope = scope.joins(:group).where(groups: { handle: params[:group_handle] }) if params[:group_handle].present?
    render_collection scope, blueprint: BadgeClassBlueprint
  end

  # GET /api/v1/badge_classes/by_user
  def by_user
    user = User.find_by!(handle: params[:handle])
    group_ids = user.memberships.pluck(:group_id)
    render json: BadgeClassBlueprint.render(BadgeClass.where(group_id: group_ids))
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /api/v1/badge_classes/:id/invites
  def invites
    invites = @badge_class.group ? @badge_class.group.group_invites.where("expires_at > ? OR expires_at IS NULL", Time.current) : GroupInvite.none
    render json: {
      badge_class: BadgeClassBlueprint.render_as_hash(@badge_class),
      invites: GroupInviteBlueprint.render_as_hash(invites.includes(:sender, :receiver))
    }
  end

  private

  def set_badge_class
    @badge_class = BadgeClass.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def badge_class_params
    params.require(:badge_class).permit(:name, :title, :group_id, :metadata, :image_url,
      :transferable, :revocable, :weighted, :encrypted, :badge_type, :display, :content)
  end
end
