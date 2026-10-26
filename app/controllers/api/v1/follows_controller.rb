class Api::V1::FollowsController < Api::BaseController
  skip_before_action :authenticate!, only: :index
  before_action :authenticate_optional!, only: :index

  # GET /api/v1/follows
  #
  # The default list is the signed-in user's outgoing follows. Public profile
  # pages pass user_id (who they follow) or direction=followers with target_id
  # (who follows that user or group). include=profiles embeds the person and
  # the target so a screen does not fetch each row again.
  def index
    scope = follow_scope
    return if performed?

    if params[:include] == "profiles"
      render_with_profiles(scope.order(created_at: :desc))
    else
      render_collection scope.order(created_at: :desc), blueprint: FollowBlueprint
    end
  end

  # GET /api/v1/follows/feed?city=
  #
  # The follow tab: recommendations written by people the viewer follows, and
  # rollups of those people attending a published event when they share
  # activity. Blocked authors are left out. A city keeps only that city's events.
  def feed
    followed = current_user.follows.active.where(target_type: "User").where.not(target_id: current_user.blocks.select(:target_user_id)).pluck(:target_id)
    sharing = User.where(id: followed).select { |user| ActiveModel::Type::Boolean.new.cast(user.data["share_activity"]) }.map(&:id)
    city = params[:city].presence
    items = recommendation_items(followed, city) + rollup_items(sharing, city)
    items.sort_by! { |item| item["created_at"].to_s }
    items.reverse!
    render_page(items)
  end

  def create
    follow = current_user.follows.find_or_initialize_by(
      target_type: params[:target_type], target_id: params[:target_id]
    )
    follow.status = "active"
    if follow.save
      render json: FollowBlueprint.render(follow), status: follow.previously_new_record? ? :created : :ok
    else
      render_error(follow.errors.full_messages.join(", "))
    end
  end

  def destroy
    follow = current_user.follows.find(params[:id])
    follow.update!(status: "inactive")
    head :no_content
  end

  private

  def follow_scope
    if params[:direction] == "followers" && params[:target_id].present?
      Follow.active.where(target_type: params[:target_type].presence || "User", target_id: params[:target_id])
    elsif params[:user_id].present?
      Follow.active.where(user_id: params[:user_id])
    elsif current_user
      current_user.follows.active
    else
      render json: { error: "Unauthorized" }, status: :unauthorized
      Follow.none
    end
  end

  def render_with_profiles(scope)
    limit = params.fetch(:limit, PAGY_DEFAULT_LIMIT).to_i
    limit = PAGY_DEFAULT_LIMIT if limit <= 0
    pagy = Pagy::Offset.new(count: scope.count, page: params.fetch(:page, 1).to_i, limit: [ limit, PAGY_MAX_LIMIT ].min)
    rows = pagy.records(scope.includes(:user)).map { |follow| profile_row(follow) }
    render json: { data: rows, meta: pagy_metadata(pagy) }
  end

  def profile_row(follow)
    row = JSON.parse(FollowBlueprint.render(follow))
    row["user"] = JSON.parse(UserBlueprint.render(follow.user, view: :profile))
    target = follow.target_type == "Group" ? Group.find_by(id: follow.target_id) : User.find_by(id: follow.target_id)
    row["target"] = if target.is_a?(Group)
      JSON.parse(GroupBlueprint.render(target, view: :card))
    elsif target
      JSON.parse(UserBlueprint.render(target, view: :profile))
    end
    row
  end

  def recommendation_items(author_ids, city)
    return [] if author_ids.empty?

    comments = Comment.visible.includes(:user).where(comment_type: "recommendation", item_type: "Event", user_id: author_ids).order(created_at: :desc).limit(40)
    events = Event.includes(:group, :place, :venue, :owner, :track, tickets: :payment_methods).where(id: comments.map(&:item_id), status: "published").index_by(&:id)
    comments.filter_map do |comment|
      event = events[comment.item_id]
      next unless event
      next if city && event.city != city

      {
        "type" => "recommendation",
        "id" => comment.id,
        "text" => comment.content,
        "created_at" => comment.created_at,
        "author" => JSON.parse(UserBlueprint.render(comment.user, view: :profile)),
        "event" => JSON.parse(EventBlueprint.render(event))
      }
    end
  end

  def rollup_items(user_ids, city)
    return [] if user_ids.empty?

    events = Event.where(status: "published").where("end_time >= ?", Time.current)
    events = events.where(city: city) if city
    participants = Participant.confirmed_public.where(user_id: user_ids, event_id: events.select(:id)).includes(:user)
    participants.group_by(&:event_id).filter_map do |event_id, rows|
      event = Event.includes(:group, :place, :venue, :owner, :track, tickets: :payment_methods).find_by(id: event_id)
      next unless event

      actors = rows.map { |participant| JSON.parse(UserBlueprint.render(participant.user, view: :profile)) }
      {
        "type" => "registration_rollup",
        "id" => "attendance-#{event.id}",
        "created_at" => event.updated_at,
        "count" => actors.size,
        "actors" => actors,
        "event" => JSON.parse(EventBlueprint.render(event))
      }
    end
  end

  def render_page(items)
    limit = params.fetch(:limit, 20).to_i
    limit = 20 if limit <= 0
    limit = [ limit, 50 ].min
    page = [ params.fetch(:page, 1).to_i, 1 ].max
    total_pages = (items.size.to_f / limit).ceil
    total_pages = 1 if total_pages.zero?
    offset = (page - 1) * limit
    render json: {
      data: items.slice(offset, limit) || [],
      meta: {
        page: page,
        limit: limit,
        total: items.size,
        total_pages: total_pages,
        next_page: page < total_pages ? page + 1 : nil,
        prev_page: page > 1 ? page - 1 : nil
      }
    }
  end
end
