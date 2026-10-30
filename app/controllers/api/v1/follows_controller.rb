class Api::V1::FollowsController < Api::BaseController
  # Profile pages list someone else's follows and followers without a session.
  # Creating or removing a follow still requires the follower's own token.
  # A request with no subject (`GET /follows` from FollowButton) is the
  # caller's own list, so that one stays authenticated.
  skip_before_action :authenticate!, only: :index
  before_action :authenticate_optional!, only: :index

  # GET /api/v1/follows
  #
  # The clients call three shapes, always with include=profiles:
  #   ?user_id=           that user's outgoing follows (target embedded)
  #   ?direction=followers&target_id=&target_type=User|Group
  #                       who follows that target (user embedded)
  #   (no subject)        the signed-in user's outgoing follows
  def index
    scope = Follow.order(created_at: :desc, id: :desc)
    if params[:direction].to_s == "followers"
      target_type = params[:target_type].presence || "User"
      return render_error("target_type must be User or Group") unless Follow::TARGET_TYPES.include?(target_type)
      return render_error("target_id is required") if params[:target_id].blank?

      target = resolve_target!(target_type, params[:target_id])
      scope = scope.where(target_type: target_type, target_id: target.id)
    else
      user = subject_user
      return if performed?

      scope = scope.where(user_id: user.id)
    end
    scope = scope.includes(:user, :target) if include_profiles?
    render_collection scope, blueprint: FollowBlueprint, include_profiles: include_profiles?
  end

  # POST /api/v1/follows  {target_type, target_id}
  # Repeating a follow returns the existing row so a double tap still yields an id.
  def create
    target_type = params[:target_type].to_s
    return render_error("target_type must be User or Group") unless Follow::TARGET_TYPES.include?(target_type)
    return render_error("target_id is required") if params[:target_id].blank?

    target = resolve_target!(target_type, params[:target_id])
    if target_type == "User" && target.id == current_user.id
      return render_error("cannot follow yourself")
    end

    follow = Follow.find_or_initialize_by(user: current_user, target_type: target_type, target_id: target.id)
    created = follow.new_record?
    follow.status = "active"
    begin
      follow.save!
    rescue ActiveRecord::RecordNotUnique
      follow = Follow.find_by!(user: current_user, target_type: target_type, target_id: target.id)
      created = false
    rescue ActiveRecord::RecordInvalid
      return render_error(follow.errors.full_messages.join(", "))
    end

    render json: FollowBlueprint.render(follow, include_profiles: true), status: created ? :created : :ok
  end

  # DELETE /api/v1/follows/:id
  def destroy
    follow = Follow.find(params[:id])
    return render_error("not authorized", status: :forbidden) unless follow.user_id == current_user.id

    follow.destroy!
    render json: { result: "ok" }
  end

  private

  def include_profiles?
    params[:include].to_s.split(",").map(&:strip).include?("profiles")
  end

  # `user_id` may be a TSID, a username, or "me". Absent means the caller.
  def subject_user
    if params[:user_id].blank?
      return current_user if current_user

      render json: { error: "Unauthorized" }, status: :unauthorized
      return nil
    end

    if params[:user_id] == "me"
      return current_user if current_user

      render json: { error: "Unauthorized" }, status: :unauthorized
      return nil
    end

    User.resolve!(params[:user_id])
  end

  def resolve_target!(type, identifier)
    case type
    when "User" then User.resolve!(identifier)
    when "Group" then Group.resolve!(identifier)
    else raise ActiveRecord::RecordNotFound
    end
  end
end
