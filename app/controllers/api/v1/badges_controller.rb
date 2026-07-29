class Api::V1::BadgesController < Api::BaseController
  # Badge browsing pages (profile badges, badge detail) are public.
  skip_before_action :authenticate!, only: %i[index show]
  before_action :set_badge, only: %i[show update transfer burn swap swap_code]

  # GET /api/v1/badges/:id
  def show
    render json: BadgeBlueprint.render(@badge)
  end

  # GET /api/v1/badges
  def index
    badges = Badge.where(status: "minted")
    if params[:user_id].present?
      user = User.find(params[:user_id])
      badges = badges.where(owner_id: user.id) if params[:owned_badges]
      badges = badges.where(creator_id: user.id) if params[:created_badges]
    end
    badges = badges.joins(:owner).where(users: { name: params[:owner_handle] }) if params[:owner_handle].present?
    badges = badges.where(badge_class_id: params[:badge_class_id]) if params[:badge_class_id].present?
    # created_at alone isn't a stable sort key — many rows share an identical
    # timestamp (e.g. everything the migration backfilled with `NOW`), and an
    # undecided tiebreak would let ties shuffle between pages, causing
    # requestAllPages callers to see duplicate/missing rows across pages.
    render_collection badges.includes(:badge_class, :creator, :owner).order(created_at: :desc, id: :asc),
      blueprint: BadgeBlueprint
  end

  # PATCH /api/v1/badges/:id
  def update
    authorize @badge, :update?, policy_class: BadgePolicy
    return render_error("invalid display") unless Badge.displays.key?(params[:display].to_s)

    if @badge.update(display: params[:display])
      render json: BadgeBlueprint.render(@badge)
    else
      render_error(@badge.errors.full_messages.join(", "))
    end
  end

  # POST /api/v1/badges/:id/transfer
  def transfer
    authorize @badge, :own?, policy_class: BadgePolicy
    target = User.find_by(name: params[:target])
    return render_error("target not found") unless target
    return render_error("cannot transfer to self") if target.id == current_user.id
    return render_error("badge is not transferable") unless @badge.badge_class.transferable
    return render_error("badge is not owned/accepted") unless @badge.held?

    @badge.update(owner_id: target.id)
    Activity.create(item: @badge, initiator: current_user, action: "badge/transfer", receiver: target)
    render json: { result: "ok" }
  end

  # POST /api/v1/badges/:id/burn
  def burn
    authorize @badge, :own?, policy_class: BadgePolicy
    return render_error("badge is not minted") unless @badge.status == "minted"

    @badge.update(status: "burned")
    Activity.create(item: @badge, initiator: current_user, action: "badge/burn")
    render json: { result: "ok" }
  end

  # POST /api/v1/badges/:id/swap_code
  def swap_code
    authorize @badge, :own?, policy_class: BadgePolicy
    return render_error("badge is not owned/accepted") unless @badge.held?
    return render_error("badge is not transferable") unless @badge.badge_class.transferable

    token = @badge.gen_swap_code
    render json: { result: "ok", token: token, badge_id: @badge.id }
  end

  # POST /api/v1/badges/:id/swap
  def swap
    authorize @badge, :own?, policy_class: BadgePolicy
    # Guard the caller's OWN badge too — swap must not move a burned or
    # non-transferable badge just because the target is transferable.
    return render_error("badge is not transferable") unless @badge.badge_class.transferable
    return render_error("badge is not owned/accepted") unless @badge.held?

    target_badge = Badge.find(Badge.decode_swap_code(params[:swap_token]))
    return render_error("target badge is not owned/accepted") unless target_badge.held?
    return render_error("target badge is not transferable") unless target_badge.badge_class.transferable

    previous_owner_id = target_badge.owner_id
    target_badge.update(owner_id: @badge.owner_id)
    @badge.update(owner_id: previous_owner_id)
    Activity.create(item: @badge, initiator: current_user, action: "badge/swap")
    render json: { result: "ok" }
  rescue JwtService::Error, ActiveRecord::RecordNotFound
    render_error("invalid swap token")
  end

  private

  def set_badge
    @badge = Badge.find_by_id_or_legacy!(params[:id])
  end
end
