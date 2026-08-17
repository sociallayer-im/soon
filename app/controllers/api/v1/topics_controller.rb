class Api::V1::TopicsController < Api::BaseController
  include DiscussionRateLimit
  include DiscussionGate

  before_action :require_discussion_enabled!
  skip_before_action :authenticate!, only: %i[index show]
  before_action :authenticate_optional!, only: %i[index show]
  before_action :set_topic, only: %i[show update destroy pin unpin close open flag unflag restore]

  # GET /api/v1/topics?group_id=&category_id=&category_slug=&tags=&search=
  #                   &user_id=&starred_id=&collection=
  #
  # Public. Every read starts from the same two scopes — the boards this
  # caller may see, and the topics within them that are not hidden from them.
  # Skipping either one is how a private board leaks.
  def index
    group = Group.resolve!(params[:group_id])
    return render_not_found unless group.discussion_enabled?

    scope = visible_topics(group).where(group_id: group.id)
    scope = apply_filters(scope, group)
    scope = apply_collection(scope)

    render_collection scope.includes(:user, :last_reply_user, :category),
                      blueprint: TopicBlueprint, starred_ids: starred_ids(scope)
  end

  def show
    # 404 rather than 403 for something this caller may not see: a 403 confirms
    # the thing exists, and on a private board the title alone can be the
    # secret. Same rule as the deployment gate.
    return render_not_found unless TopicPolicy.new(current_user, @topic).show?

    render json: TopicBlueprint.render(@topic, view: :detail,
      current_user: current_user, starred_ids: starred_ids_for([ @topic ]))
  end

  def create
    category = Category.find_by(id: topic_params[:category_id])
    return render_not_found if category.nil?
    return render_not_found unless category.group.discussion_enabled?

    # An invisible board must not answer differently from one that does not
    # exist — a 403 here would confirm a private board's id.
    return render_not_found unless category.visible_to?(current_user)

    topic = Topic.new(topic_params.except(:category_id))
    topic.category = category
    topic.group    = category.group
    topic.user     = current_user
    authorize topic, :create?

    return if rate_limited?(:topic, group: category.group)

    topic.save!
    record_rate_limit(:topic)
    render json: TopicBlueprint.render(topic, view: :detail, current_user: current_user),
           status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # PATCH /api/v1/topics/:id — moving between boards is a manager action,
  # because it changes who can see the topic.
  def update
    authorize @topic, :update?

    attrs = topic_params.except(:category_id)
    if topic_params[:category_id].present? && topic_params[:category_id] != @topic.category_id
      authorize @topic, :move?
      target = Category.find_by(id: topic_params[:category_id])
      return render_not_found if target.nil?
      # Cross-group moves are refused by the model too; caught here to give a
      # useful message rather than a validation string.
      if target.group_id != @topic.group_id
        return render_error("cannot move a topic to another group's category")
      end

      attrs = attrs.merge(category_id: target.id)
    end

    previous_category_id = @topic.category_id
    @topic.update!(attrs)
    if previous_category_id != @topic.category_id
      Category.find_by(id: previous_category_id)&.refresh_topics_count!
      @topic.category.refresh_topics_count!
    end
    render json: TopicBlueprint.render(@topic.reload, view: :detail, current_user: current_user)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def destroy
    authorize @topic, :destroy?
    @topic.soft_delete!(by: current_user)
    @topic.category.refresh_topics_count!
    render json: { result: "ok" }
  end

  def restore
    authorize @topic, :restore?
    @topic.restore!
    @topic.category.refresh_topics_count!
    render json: { result: "ok" }
  end

  def pin
    authorize @topic, :pin?
    @topic.update!(pinned_at: Time.current)
    render json: { result: "ok" }
  end

  def unpin
    authorize @topic, :pin?
    @topic.update!(pinned_at: nil)
    render json: { result: "ok" }
  end

  def close
    authorize @topic, :close?
    @topic.update!(closed_at: Time.current)
    render json: { result: "ok" }
  end

  def open
    authorize @topic, :close?
    @topic.update!(closed_at: nil)
    render json: { result: "ok" }
  end

  def flag
    authorize @topic, :flag?
    @topic.flag!(by: current_user, reason: params[:reason])
    render json: { result: "ok" }
  end

  def unflag
    authorize @topic, :flag?
    @topic.unflag!
    render json: { result: "ok" }
  end

  private

  # A soft-deleted topic is invisible to everyone including its author, so it
  # is not fetched here at all — restore has to reach past the default scope.
  def set_topic
    @topic = if action_name == "restore"
      Topic.with_deleted.find(params[:id])
    else
      Topic.find(params[:id])
    end
    # The group's switch, checked against the topic rather than a parameter —
    # otherwise every by-id action stays open after a group turns its forum off.
    require_group_discussion!(@topic.group)
  end

  # Managers see flagged topics in the list so they can review what they (or
  # a colleague) hid; everyone else never receives them.
  def visible_topics(group)
    manager = GroupPolicy.new(current_user, group).manage?
    Topic.in_visible_categories(current_user).visible_to(current_user, manager: manager)
  end

  def apply_filters(scope, group)
    if params[:category_id].present?
      scope = scope.where(category_id: params[:category_id])
    elsif params[:category_slug].present?
      category = Category.visible_to(current_user, group: group)
                         .find_by(slug: params[:category_slug])
      return scope.none if category.nil?

      scope = scope.where(category_id: category.id)
    end

    scope = scope.where("tags && ARRAY[?]::varchar[]", params[:tags].to_s.split(",")) if params[:tags].present?
    scope = scope.where("title ILIKE ?", "%#{escape_like(params[:search])}%") if params[:search].present?
    scope = scope.where(user_id: User.resolve!(params[:user_id]).id) if params[:user_id].present?

    if params[:starred_id].present?
      starrer = User.resolve!(params[:starred_id])
      scope = scope.where(id: star_scope(starrer).select(:item_id))
    end

    scope
  end

  def apply_collection(scope)
    case params[:collection]
    when "newest"     then scope.order(created_at: :desc, id: :desc)
    when "unanswered" then scope.where(replies_count: 0).recently_active
    else scope.order(Arel.sql("pinned_at DESC NULLS LAST")).recently_active
    end
  end

  # % and _ are LIKE metacharacters, so an unescaped search box is a search box
  # where typing "_" matches everything. Nothing can escape the scope this way —
  # the query is still parameterised and still bounded by the visibility scopes
  # — but the results are wrong, and a bare "%" makes the endpoint return the
  # whole board as if it were a match.
  def escape_like(term)
    term.to_s.gsub(/[\\%_]/) { |ch| "\\#{ch}" }
  end

  def star_scope(user)
    Comment.where(user_id: user.id, comment_type: "star", item_type: "Topic",
                  removed: [ nil, false ])
  end

  # One query for the whole page rather than one per card.
  def starred_ids(scope)
    return [] if current_user.nil?

    star_scope(current_user).where(item_id: scope.reselect(:id)).pluck(:item_id)
  end

  def starred_ids_for(topics)
    return [] if current_user.nil?

    star_scope(current_user).where(item_id: topics.map(&:id)).pluck(:item_id)
  end

  def topic_params
    params.require(:topic).permit(:category_id, :title, :content, :content_type,
                                  :image_url, tags: [])
  end
end
