require "csv"

class Api::V1::HackathonsController < Api::BaseController
  include HackathonGate

  before_action :require_hackathon_enabled!
  skip_before_action :authenticate!, only: %i[index show]
  before_action :authenticate_optional!, only: %i[index show]
  before_action :set_hackathon, only: %i[show update destroy publish unpublish tracks
                                         flag unflag restore export judges_team]

  # GET /api/v1/hackathons?group_id=&status=draft|published
  def index
    group = Group.resolve!(params[:group_id])
    return render_not_found unless group.hackathon_enabled?

    manager = GroupPolicy.new(current_user, group).manage?
    scope = Hackathon.visible_to(current_user, manager: manager).where(group_id: group.id)
    scope = scope.where(status: params[:status]) if params[:status].in?(Hackathon::STATUSES)

    render_collection scope.includes(:user).order(created_at: :desc, id: :desc),
                      blueprint: HackathonBlueprint
  end

  def show
    return render_not_found unless HackathonPolicy.new(current_user, @hackathon).show?

    render_detail(@hackathon)
  end

  def create
    group = Group.resolve!(hackathon_params[:group_id])
    return render_not_found unless group.hackathon_enabled?

    hackathon = Hackathon.new(hackathon_params.except(:group_id, :tracks))
    hackathon.group = group
    hackathon.user  = current_user
    authorize hackathon, :create?

    Hackathon.transaction do
      hackathon.save!
      hackathon.replace_tracks!(hackathon_params[:tracks]) if hackathon_params.key?(:tracks)
    end
    render_detail(hackathon, status: :created)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def update
    authorize @hackathon, :update?
    Hackathon.transaction do
      @hackathon.update!(hackathon_params.except(:group_id, :tracks))
      @hackathon.replace_tracks!(hackathon_params[:tracks]) if hackathon_params.key?(:tracks)
    end
    render_detail(@hackathon.reload)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # PATCH /api/v1/hackathons/:id/tracks  { tracks: [{id?, title, description, color}] }
  def tracks
    authorize @hackathon, :update?
    @hackathon.replace_tracks!(params.permit(tracks: [ :id, :title, :description, :color ])[:tracks])
    render_detail(@hackathon.reload)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def destroy
    authorize @hackathon, :destroy?
    @hackathon.soft_delete!(by: current_user)
    render json: { result: "ok" }
  end

  def restore
    authorize @hackathon, :restore?
    @hackathon.restore!
    render json: { result: "ok" }
  end

  def publish
    authorize @hackathon, :publish?
    @hackathon.update!(status: "published")
    render_detail(@hackathon)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def unpublish
    authorize @hackathon, :publish?
    @hackathon.update!(status: "draft")
    render_detail(@hackathon)
  end

  def flag
    authorize @hackathon, :flag?
    @hackathon.flag!(by: current_user, reason: params[:reason])
    render json: { result: "ok" }
  end

  def unflag
    authorize @hackathon, :flag?
    @hackathon.unflag!
    render json: { result: "ok" }
  end

  # POST /api/v1/hackathons/:id/judges_team — snapshot the registration
  # event's judges into a group Team so a poll can name them as eligible
  # voters (design/HACKATHON_MODULE.md §6). Idempotent by slug: re-running
  # diffs the roster. Judges without an account cannot be on a team and are
  # returned in `skipped`.
  def judges_team
    authorize @hackathon, :update?
    return render_error("no registration event") if @hackathon.event.nil?

    roles = @hackathon.event.event_roles.where(role: "judge")
    with_account = roles.where(item_type: "User").where.not(item_id: nil)
    user_ids = User.where(id: with_account.pluck(:item_id)).pluck(:id)
    skipped  = roles.where.not(id: with_account).map { |r| r.display_name.presence || r.email }

    slug = "judges-#{@hackathon.id}"[0, 40].downcase
    team = @hackathon.group.teams.find_or_initialize_by(slug: slug)
    added = removed = 0
    Team.transaction do
      team.assign_attributes(name: "#{@hackathon.title} judges"[0, 60], is_public: false, archived: false) if team.new_record?
      team.save!
      # A judge who is not yet a group member cannot be on a team; they show
      # up in `skipped` rather than raising.
      member_ids = Membership.where(group_id: @hackathon.group_id, user_id: user_ids).pluck(:user_id)
      skipped += User.where(id: user_ids - member_ids).map { |u| u.nickname.presence || u.name }
      current = team.team_memberships.pluck(:user_id)
      (member_ids - current).each { |uid| team.team_memberships.create!(user_id: uid); added += 1 }
      removed = team.team_memberships.where(user_id: current - member_ids).destroy_all.size
      team.refresh_members_count!
    end
    render json: { team: JSON.parse(TeamRefBlueprint.render(team)), added: added, removed: removed, skipped: skipped }
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # GET /api/v1/hackathons/:id/export — projects CSV, organisers only.
  def export
    authorize @hackathon, :export?
    csv = CSV.generate do |out|
      out << %w[title track status award owner members stars repo_url demo_url video_url submitted_at]
      @hackathon.hackathon_projects.includes(:user, hackathon_project_members: :user).order(:created_at).each do |p|
        out << [ p.title, p.track&.dig("title"), p.status, p.award,
                 p.user.name, p.hackathon_project_members.map { |m| m.user.name }.join("; "),
                 p.stars_count, p.repo_url, p.demo_url, p.video_url, p.submitted_at&.iso8601 ]
      end
    end
    send_data csv, type: "text/csv; charset=utf-8", filename: "hackathon-#{@hackathon.id}-projects.csv"
  end

  private

  def set_hackathon
    @hackathon = if action_name == "restore"
      Hackathon.with_deleted.find(params[:id])
    else
      Hackathon.find(params[:id])
    end
    require_group_hackathon!(@hackathon.group)
  end

  def render_detail(hackathon, status: :ok)
    render json: HackathonBlueprint.render(hackathon, view: :detail, current_user: current_user), status: status
  end

  def hackathon_params
    params.require(:hackathon).permit(:group_id, :event_id, :title, :tagline, :content, :cover_url,
                                      :start_at, :end_at, :submit_open_at, :submit_close_at,
                                      :projects_visibility, :can_submit_project,
                                      tracks: [ :id, :title, :description, :color ])
  end
end
