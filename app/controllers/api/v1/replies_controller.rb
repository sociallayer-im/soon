class Api::V1::RepliesController < Api::BaseController
  include DiscussionRateLimit
  include DiscussionGate

  before_action :require_discussion_enabled!
  skip_before_action :authenticate!, only: :index
  before_action :authenticate_optional!, only: :index
  before_action :set_reply, only: %i[update destroy flag unflag restore]

  # GET /api/v1/topics/:topic_id/replies — chronological, the way a thread is
  # read. Gated on the topic being visible, which in turn is gated on its
  # board: a private board's floors must not be reachable by knowing an id.
  def index
    topic = Topic.find(params[:topic_id])
    return unless require_group_discussion!(topic.group)
    return render_not_found unless TopicPolicy.new(current_user, topic).show?

    manager = GroupPolicy.new(current_user, topic.group).manage?
    scope = topic.replies.visible_to(current_user, manager: manager).chronological
    render_collection scope.includes(:user, reply_to: :user),
                      blueprint: ReplyBlueprint, view: :with_permissions,
                      current_user: current_user, can_manage: manager,
                      starred_reply_ids: starred_reply_ids(scope)
  end

  def create
    topic = Topic.find(params[:topic_id])
    return unless require_group_discussion!(topic.group)
    return render_not_found unless TopicPolicy.new(current_user, topic).show?

    reply = topic.replies.new(reply_params)
    reply.user = current_user
    authorize reply, :create?

    return if rate_limited?(:reply, group: topic.group)

    reply.save!
    record_rate_limit(:reply)
    render json: ReplyBlueprint.render(reply, view: :with_permissions,
      current_user: current_user,
      can_manage: GroupPolicy.new(current_user, topic.group).manage?), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def update
    authorize @reply, :update?
    @reply.update!(reply_params.except(:reply_to_id))
    render json: ReplyBlueprint.render(@reply, view: :with_permissions,
      current_user: current_user,
      can_manage: GroupPolicy.new(current_user, @reply.topic.group).manage?)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def destroy
    authorize @reply, :destroy?
    @reply.soft_delete!(by: current_user)
    @reply.topic.refresh_last_reply!
    render json: { result: "ok" }
  end

  def restore
    authorize @reply, :restore?
    @reply.restore!
    @reply.topic.refresh_last_reply!
    render json: { result: "ok" }
  end

  def flag
    authorize @reply, :flag?
    @reply.flag!(by: current_user, reason: params[:reason])
    render json: { result: "ok" }
  end

  def unflag
    authorize @reply, :flag?
    @reply.unflag!
    render json: { result: "ok" }
  end

  private

  # One query for the page, not one per floor.
  def starred_reply_ids(scope)
    return [] if current_user.nil?

    Comment.where(user_id: current_user.id, comment_type: "star", item_type: "Reply",
                  removed: [ nil, false ], item_id: scope.reselect(:id)).pluck(:item_id)
  end

  def set_reply
    @reply = if action_name == "restore"
      Reply.with_deleted.find(params[:id])
    else
      Reply.find(params[:id])
    end
    require_group_discussion!(@reply.topic.group)
  end

  def reply_params
    params.require(:reply).permit(:content, :content_type, :reply_to_id)
  end
end
