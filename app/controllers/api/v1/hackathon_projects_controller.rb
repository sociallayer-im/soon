class Api::V1::HackathonProjectsController < Api::BaseController
  include HackathonGate

  before_action :require_hackathon_enabled!
  skip_before_action :authenticate!, only: %i[index show]
  before_action :authenticate_optional!, only: %i[index show]
  before_action :set_project, except: %i[index create]

  # GET /api/v1/hackathon_projects?hackathon_id=&track_id=&recruiting=&status=&sort=stars|newest
  def index
    hackathon = Hackathon.find(params[:hackathon_id])
    return render_not_found unless require_group_hackathon!(hackathon.group)
    return render_not_found unless HackathonPolicy.new(current_user, hackathon).show?

    policy = HackathonPolicy.new(current_user, hackathon)
    scope = hackathon.hackathon_projects
    scope = visible_scope(scope, hackathon, manager: policy.manage?)
    scope = scope.where(track_id: params[:track_id]) if params[:track_id].present?
    scope = scope.where(recruiting: true) if params[:recruiting] == "true"
    case params[:status]
    when "draft"     then scope = scope.drafts
    when "submitted" then scope = scope.submitted
    when "approved"  then scope = scope.where.not(approved_at: nil)
    when "rejected"  then scope = scope.where.not(rejected_at: nil)
    end
    order = params[:sort] == "stars" ? { stars_count: :desc, created_at: :desc } : { created_at: :desc }

    render_collection scope.includes(:user).order(order), blueprint: HackathonProjectBlueprint
  end

  def show
    return render_not_found unless HackathonProjectPolicy.new(current_user, @project).show?

    render_detail(@project)
  end

  def create
    hackathon = Hackathon.find(project_params[:hackathon_id])
    return render_not_found unless require_group_hackathon!(hackathon.group)

    project = HackathonProject.new(project_params.except(:hackathon_id))
    project.hackathon = hackathon
    project.user      = current_user
    authorize project, :create?

    HackathonProject.transaction do
      project.save!
      project.hackathon_project_members.create!(user: current_user, role: "owner")
    end
    render_detail(project.reload, status: :created)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def update
    authorize @project, :update?
    @project.update!(project_params.except(:hackathon_id))
    render_detail(@project)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # Drafts only (policy). Hard delete — see HackathonProject.
  def destroy
    authorize @project, :destroy?
    @project.destroy!
    render json: { result: "ok" }
  end

  def submit
    return render_error(submit_refusal) unless HackathonProjectPolicy.new(current_user, @project).submit?

    @project.submit!
    render_detail(@project)
  end

  def unsubmit
    authorize @project, :unsubmit?
    @project.unsubmit!
    render_detail(@project)
  end

  # POST /review  { decision: "approve"|"reject", note }
  def review
    authorize @project, :review?
    return render_error("project has not been submitted") unless @project.submitted?

    case params[:decision]
    when "approve" then @project.approve!(note: params[:note])
    when "reject"  then @project.reject!(note: params[:note])
    else return render_error("decision must be approve or reject")
    end
    render_detail(@project)
  end

  # POST /award  { award: "Best idea" | null }
  def award
    authorize @project, :award?
    @project.update!(award: params[:award].presence)
    render_detail(@project)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def star
    authorize @project, :star?
    @project.hackathon_project_stars.find_or_create_by!(user: current_user)
    render_detail(@project.reload)
  end

  def unstar
    authorize @project, :star?
    @project.hackathon_project_stars.where(user: current_user).destroy_all
    render_detail(@project.reload)
  end

  def leave
    authorize @project, :leave?
    @project.hackathon_project_members.where(user: current_user).destroy_all
    render_detail(@project.reload)
  end

  # POST /members { user_id } — the owner adds someone; there is no self-join
  # (design/HACKATHON_MODULE.md §1.2). The person needs the same standing as
  # the owner had to create the project, and a free slot in this hackathon.
  def add_member
    authorize @project, :manage_members?
    return render_error("members are locked after submission") if @project.submitted?
    user = User.find(params[:user_id])
    unless HackathonPolicy.new(user, @project.hackathon).can_submit_project?
      return render_error("that person is not eligible to take part")
    end

    @project.hackathon_project_members.create!(user: user)
    render_detail(@project.reload)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def remove_member
    authorize @project, :manage_members?
    return render_error("the owner cannot be removed; transfer ownership first") if params[:user_id] == @project.user_id

    @project.hackathon_project_members.where(user_id: params[:user_id]).destroy_all
    render_detail(@project.reload)
  end

  # POST /transfer { user_id }
  def transfer
    authorize @project, :manage_members?
    @project.transfer_to!(User.find(params[:user_id]))
    render_detail(@project.reload)
  rescue ActiveRecord::RecordNotFound
    render_error("new owner must already be a member")
  end

  def flag
    authorize @project, :flag?
    @project.flag!(by: current_user, reason: params[:reason])
    render json: { result: "ok" }
  end

  def unflag
    authorize @project, :flag?
    @project.unflag!
    render json: { result: "ok" }
  end

  private

  def set_project
    @project = HackathonProject.find(params[:id])
    require_group_hackathon!(@project.hackathon.group)
  end

  # The list form of HackathonProjectPolicy#show?: own projects always,
  # then whatever the visibility setting lets out.
  def visible_scope(scope, hackathon, manager:)
    return scope if manager

    mine = current_user ? HackathonProjectMember.where(hackathon_id: hackathon.id, user_id: current_user.id).select(:project_id) : nil
    public_scope = scope.not_flagged.submitted
    public_scope = case hackathon.projects_visibility
    when "always"       then public_scope
    when "after_submit" then hackathon.submission_closed? ? public_scope : scope.none
    else                     public_scope.where.not(approved_at: nil)
    end
    # Recruiting drafts are listable by anyone eligible so people can find a
    # team; the card carries no content.
    recruiting = params[:recruiting] == "true" ? scope.not_flagged.drafts.where(recruiting: true) : scope.none
    result = public_scope.or(recruiting)
    result = result.or(scope.where(id: mine)) if mine
    result
  end

  def submit_refusal
    h = @project.hackathon
    return "only the owner can submit" unless @project.owner?(current_user)
    return "already submitted" if @project.submitted?
    return "submissions are not open" unless h.submission_open?

    "cannot submit"
  end

  def render_detail(project, status: :ok)
    render json: HackathonProjectBlueprint.render(project, view: :detail, current_user: current_user), status: status
  end

  def project_params
    params.require(:hackathon_project).permit(:hackathon_id, :track_id, :title, :tagline, :content, :cover_url,
                                              :repo_url, :demo_url, :video_url, :recruiting,
                                              tech: [], seeking: [])
  end
end
