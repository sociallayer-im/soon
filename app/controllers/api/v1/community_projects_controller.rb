class Api::V1::CommunityProjectsController < Api::BaseController
  skip_before_action :authenticate!, only: %i[index show comments]
  before_action :authenticate_optional!, only: %i[index show comments]
  before_action :prevent_shared_cache
  before_action :set_group
  before_action :set_project, except: %i[index create]
  rescue_from ActiveRecord::RecordInvalid do |error|
    render_error(error.record.errors.full_messages.join(", "))
  end

  def index
    projects = CommunityProject.where(group: @group)
    visible = projects.where(status: "published")
    if current_user
      visible = visible.or(projects.where(user: current_user))
    end
    render json: page(visible.includes(:user).order(Arel.sql("published_at DESC NULLS LAST"), created_at: :desc, id: :desc)) { |p| project_json(p) }
  end

  def show
    render json: project_json(@project).merge(
      members: @project.members.includes(:user).order(:created_at).filter_map do |member|
        next if !member.accepted_at && !author? && member.user_id != current_user&.id

        { id: member.id, user: profile(member.user), role: member.role, accepted: member.accepted_at.present? }
      end
    )
  end

  def create
    require_member!
    project = CommunityProject.new(project_params.merge(group: @group, user: current_user))
    save_project!(project)
    render json: project_json(project), status: :created
  end

  def update
    raise Pundit::NotAuthorizedError unless author? && @project.status != "hidden"

    @project.assign_attributes(project_params)
    save_project!(@project)
    render json: project_json(@project)
  end

  def hide
    raise Pundit::NotAuthorizedError unless manager?

    @project.update!(status: "hidden")
    head :no_content
  end

  def invite
    raise Pundit::NotAuthorizedError unless author? && @project.status == "published"

    member_user = User.find_by!(name: params.require(:username).strip)
    return render_error("The submitter is already part of the project") if member_user == current_user

    member = @project.members.create_or_find_by!(user: member_user) { |record| record.role = params[:role] }
    render json: { id: member.id, user: profile(member_user), role: member.role, accepted: member.accepted_at.present? }, status: :created
  end

  def accept
    member = @project.members.find_by!(id: params[:member_id], user: current_user)
    raise Pundit::NotAuthorizedError unless @project.status == "published"

    member.update!(accepted_at: member.accepted_at || Time.current)
    head :no_content
  end

  def remove_member
    member = @project.members.find(params[:member_id])
    raise Pundit::NotAuthorizedError unless author? || member.user_id == current_user.id

    member.destroy!
    head :no_content
  end

  def comments
    raise ActiveRecord::RecordNotFound unless @project.status == "published"

    render json: page(@project.comments.includes(:user).order(:created_at, :id)) { |comment| comment_json(comment) }
  end

  def comment
    require_member!
    raise ActiveRecord::RecordNotFound unless @project.status == "published"

    comment = @project.comments.create!(user: current_user, content: params.require(:content))
    render json: comment_json(comment), status: :created
  end

  def remove_comment
    comment = @project.comments.find(params[:comment_id])
    raise Pundit::NotAuthorizedError unless manager? || comment.user_id == current_user.id

    comment.destroy!
    head :no_content
  end

  private

  def prevent_shared_cache
    response.headers["Cache-Control"] = "private, no-store"
  end

  def set_group
    @group = Group.find_by(id: params[:group_id]) || Group.find_by!(name: params[:group_id])
    raise ActiveRecord::RecordNotFound unless @group.community_projects_enabled?

    @membership = current_user&.memberships&.active&.find_by(group: @group)
    allowed = case @group.can_view_event
    when "manager" then manager?
    when "member" then @membership.present?
    else true
    end
    raise ActiveRecord::RecordNotFound unless allowed
  end

  def set_project
    @project = CommunityProject.where(group: @group).find(params[:id])
    raise ActiveRecord::RecordNotFound unless @project.status == "published" || author? || (@project.status == "hidden" && manager?)
  end

  def author? = current_user.present? && @project.user_id == current_user.id
  def manager? = %w[manager owner].include?(@membership&.role)

  def require_member!
    raise Pundit::NotAuthorizedError unless @membership
  end

  def project_params
    params.require(:project).permit(:title, :tagline, :content, :icon_url, :cover_url, :website_url, :status, gallery: %i[url caption])
  end

  def save_project!(project)
    raise Pundit::NotAuthorizedError unless %w[draft published].include?(project.status)

    project.published_at ||= Time.current if project.status == "published"
    project.save!
  end

  def profile(user)
    { id: user.id, name: user.name, nickname: user.nickname, image_url: user.image_url }
  end

  def project_json(project)
    project.as_json(only: %i[id title tagline content icon_url cover_url website_url gallery status published_at])
      .merge(user: profile(project.user), can_edit: current_user&.id == project.user_id && project.status != "hidden", can_hide: manager?)
  end

  def comment_json(comment)
    { id: comment.id, content: comment.content, created_at: comment.created_at,
      user: profile(comment.user), can_remove: manager? || comment.user_id == current_user&.id }
  end

  def page(scope)
    offset = [params[:page].to_i - 1, 0].max * 20
    records = scope.offset(offset).limit(21).to_a
    { data: records.first(20).map { |record| yield record }, has_more: records.size > 20 }
  end
end
