class Api::V1::BadgeClassesController < Api::BaseController
  # Badge class browsing (group badge lists, detail, by_user) is public.
  # `invites` is NOT public: GroupInviteBlueprint exposes receiver_address
  # (an email for email-type invites), so it stays behind authenticate! plus
  # an explicit group-manager check below.
  skip_before_action :authenticate!, only: %i[index show by_user]
  before_action :set_badge_class, only: %i[show invites]

  # POST /api/v1/badge_classes
  def create
    permitted = badge_class_params
    if permitted[:group_id].present?
      group = Group.find(permitted[:group_id])
      authorize group, :manage?, policy_class: GroupPolicy
    end

    badge_class = BadgeClass.new(permitted.merge(creator: current_user))
    if badge_class.save
      render json: BadgeClassBlueprint.render(badge_class), status: :created
    else
      render_error(badge_class.errors.full_messages.join(", "))
    end
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
    scope = scope.joins(:creator).where(users: { name: params[:creator_handle] }) if params[:creator_handle].present?
    scope = scope.joins(:group).where(groups: { name: params[:group_handle] }) if params[:group_handle].present?
    # See badges_controller#index: created_at alone isn't a stable sort key,
    # and ties would shuffle between pages under requestAllPages.
    render_collection scope.order(created_at: :desc, id: :asc), blueprint: BadgeClassBlueprint
  end

  # GET /api/v1/badge_classes/by_user
  def by_user
    user = User.find_by!(name: params[:handle])
    group_ids = user.memberships.pluck(:group_id)
    render json: BadgeClassBlueprint.render(BadgeClass.where(group_id: group_ids))
  end

  # GET /api/v1/badge_classes/:id/invites
  def invites
    authorize @badge_class.group, :update?, policy_class: GroupPolicy if @badge_class.group
    invites = @badge_class.group ? @badge_class.group.group_invites.where("expires_at > ? OR expires_at IS NULL", Time.current) : GroupInvite.none
    render json: {
      badge_class: BadgeClassBlueprint.render_as_hash(@badge_class),
      invites: GroupInviteBlueprint.render_as_hash(invites.includes(:sender, :receiver))
    }
  end

  private

  def set_badge_class
    @badge_class = BadgeClass.find_by_id_or_legacy!(params[:id])
  end

  def badge_class_params
    params.require(:badge_class).permit(:name, :title, :group_id, :metadata, :image_url,
      :transferable, :revocable, :weighted, :encrypted, :badge_type, :display, :content,
      :can_send_badge, permissions: [])
  end
end
