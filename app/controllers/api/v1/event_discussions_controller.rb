class Api::V1::EventDiscussionsController < Api::BaseController
  include ContentSafetyGate
  include IdempotentCreation
  include DiscussionGate
  include DiscussionRateLimit
  before_action :require_discussion_enabled!
  skip_before_action :authenticate!, only: :index
  before_action :authenticate_optional!, only: :index
  before_action :set_event

  def index
    manager = GroupPolicy.new(current_user, @event.group).manage?
    scope = Topic.in_visible_categories(current_user).visible_to(current_user, manager: manager)
      .where(event_id: @event.id)
    if params[:cursor].present?
      return render_error("cursor pagination requires sort=newest") unless params[:sort] == "newest"
      return render_newest_cursor(scope, blueprint: TopicBlueprint, view: :detail, current_user: current_user)
    end
    scope = params[:sort] == "newest" ? scope.order(created_at: :desc, id: :desc) : scope.recently_active
    render_collection scope, blueprint: TopicBlueprint, view: :detail, current_user: current_user
  end

  def create
    attrs = params.require(:discussion).permit(:title, :content, :image_url, :sync_to_community)
    return unless safe_text_submission?(attrs, scene: 3)
    return render_error("请输入分享内容") if attrs[:content].blank?
    syncing = ActiveModel::Type::Boolean.new.cast(attrs[:sync_to_community])
    if syncing && !(@event.status == "published" && %w[normal open_registration].include?(@event.visibility))
      return render_error("只有公开且已发布的活动可以同步到社区")
    end
    # Reuse an existing visible board and its posting policy; linking an event
    # must never grant permission to post to a private or manager-only board.
    category = Category.visible_to(current_user, group: @event.group).listed.sorted.find do |board|
      TopicPolicy.new(current_user, Topic.new(category: board, group: @event.group)).create?
    end
    return render_error("该群组暂无可发布的分类，请联系管理员") unless category
    topic = Topic.new(attrs.except(:sync_to_community))
    topic.assign_attributes(event: @event, category: category, group: @event.group, user: current_user,
      sync_to_community: syncing,
      title: attrs[:title].presence || attrs[:content].to_s.first(40))
    authorize topic, :create?
    return if rate_limited?(:topic, group: @event.group)
    topic.save!
    record_rate_limit(:topic)
    render json: TopicBlueprint.render(topic, view: :detail, current_user: current_user), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  private

  def set_event
    @event = Event.find(params[:event_id])
    authorize @event, :show?
    require_group_discussion!(@event.group)
  end
end
