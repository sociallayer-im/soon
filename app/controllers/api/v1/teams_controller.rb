class Api::V1::TeamsController < Api::BaseController
  include SlugGenerator

  before_action :set_team, only: %i[update destroy members add_member remove_member]

  # GET /api/v1/teams?group_id=
  #
  # Members and managers only: a team is an annotation on the roster, and the
  # roster is not public.
  def index
    group = Group.resolve!(params[:group_id])
    authorize group, :index?, policy_class: TeamPolicy

    scope = group.teams.sorted
    scope = scope.listed unless params[:include_archived] == "true"
    render_collection scope, blueprint: TeamBlueprint
  end

  def create
    group = Group.resolve!(team_params[:group_id])
    authorize group, :create?, policy_class: TeamPolicy

    team = group.teams.new(team_params.except(:group_id))
    team.slug = generate_slug(team.name, max: 30) { |s| group.teams.exists?(slug: s) } if team.slug.blank?
    team.save!
    render json: TeamBlueprint.render(team), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def update
    authorize @team
    @team.update!(team_params.except(:group_id))
    render json: TeamBlueprint.render(@team)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # DELETE /api/v1/teams/:id
  #
  # Allowed even with members, unlike a discussion board with topics. Deleting
  # a team un-groups people; it deletes nobody and orphans nothing. A board
  # that named this team stops naming it, which is why the warning belongs in
  # the UI rather than as a refusal here.
  def destroy
    authorize @team
    @team.destroy!
    render json: { result: "ok" }
  end

  def members
    authorize @team, :show?
    render_collection @team.users, blueprint: UserBlueprint
  end

  # POST /api/v1/teams/:id/members  {user_id}
  def add_member
    authorize @team, :manage_members?
    user = User.resolve!(params[:user_id])
    membership = @team.team_memberships.find_or_initialize_by(user_id: user.id)
    membership.save!
    render json: { result: "ok" }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def remove_member
    authorize @team, :manage_members?
    @team.team_memberships.find_by(user_id: User.resolve!(params[:user_id]).id)&.destroy
    render json: { result: "ok" }
  end

  private

  def set_team
    @team = Team.find(params[:id])
  end

  def team_params
    params.require(:team).permit(:group_id, :name, :slug, :description, :color,
                                 :sort, :archived, :is_public)
  end
end
