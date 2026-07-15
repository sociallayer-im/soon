class Api::V1::CommentsController < Api::BaseController
  before_action :set_comment, only: %i[remove]

  # POST /api/v1/comments
  def create
    comment = Comment.new(comment_params.merge(user: current_user))
    if comment.save
      # TODO: wire to a CommentMailer once soon/'s mail setup exists.
      render json: CommentBlueprint.render(comment), status: :created
    else
      render_error(comment.errors.full_messages.join(", "))
    end
  end

  # POST /api/v1/comments/:id/remove
  def remove
    return render_error("not authorized", status: :forbidden) unless @comment.user_id == current_user.id

    @comment.update(removed: true)
    render json: { result: "ok" }
  end

  # POST /api/v1/comments/star
  def star
    comment = Comment.find_or_initialize_by(user: current_user, item_type: params[:item_type], item_id: params[:item_id], comment_type: "star")
    comment.save
    render json: { result: "ok" }
  end

  # POST /api/v1/comments/unstar
  def unstar
    comment = Comment.find_by(user: current_user, item_type: params[:item_type], item_id: params[:item_id], comment_type: "star")
    comment&.destroy
    render json: { result: "ok" }
  end

  # GET /api/v1/comments
  def index
    comments = Comment.visible.includes(:user).where(comment_type: params[:comment_type])
    comments = comments.where(item_type: params[:item_type]) if params[:item_type].present?
    comments = comments.where(item_id: params[:item_id]) if params[:item_id].present?
    comments = comments.where(user_id: params[:user_id]) if params[:user_id].present?
    render_collection comments.order(created_at: :desc), blueprint: CommentBlueprint
  end

  private

  def set_comment
    @comment = Comment.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def comment_params
    params.require(:comment).permit(:title, :item_type, :item_id, :reply_parent_id, :content,
      :content_type, :comment_type, :icon_url, :edit_parent_id, :badge_id)
  end
end
