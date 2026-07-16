class Api::V1::TracksController < Api::BaseController
  # Track listings appear on public group pages.
  skip_before_action :authenticate!, only: %i[index show]
  before_action :set_track, only: %i[show update destroy]

  def index
    scope = Track.all
    scope = scope.where(group_id: Group.resolve!(params[:group_id]).id) if params[:group_id].present?
    render_collection scope, blueprint: TrackBlueprint
  end

  def show
    render json: TrackBlueprint.render(@track, view: :with_roles)
  end

  # POST /api/v1/tracks — group manager only. `name` (the unique slug) is
  # generated from the title when not given. manager_ids sync TrackRoles.
  def create
    group = Group.find_by(id: track_params[:group_id])
    return render_not_found unless group
    authorize group, :manage?, policy_class: GroupPolicy

    track = group.tracks.new(track_params.except(:group_id, :manager_ids))
    track.name = generate_track_name(group, track.title) if track.name.blank?

    ActiveRecord::Base.transaction do
      track.save!
      sync_managers!(track)
    end
    render json: TrackBlueprint.render(track, view: :with_roles), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # PATCH /api/v1/tracks/:id — group_id is not updatable (a track can't be
  # moved into a group whose managers never authorized it).
  def update
    authorize @track.group, :manage?, policy_class: GroupPolicy

    ActiveRecord::Base.transaction do
      @track.update!(track_params.except(:group_id, :manager_ids))
      sync_managers!(@track)
    end
    render json: TrackBlueprint.render(@track.reload, view: :with_roles)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # DELETE /api/v1/tracks/:id — events keep existing (track_id nullified).
  def destroy
    authorize @track.group, :manage?, policy_class: GroupPolicy
    @track.destroy
    head :no_content
  end

  private

  def set_track
    @track = Track.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # Replaces the track's admin roles with manager_ids (only when the param is
  # present — omitting it leaves roles untouched).
  def sync_managers!(track)
    return unless params[:track]&.key?(:manager_ids)
    ids = Array(track_params[:manager_ids]).uniq
    track.track_roles.where(role: "admin").where.not(user_id: ids).destroy_all
    ids.each do |user_id|
      role = track.track_roles.find_or_initialize_by(user_id: user_id)
      role.update!(role: "admin")
    end
  end

  # Track names are globally unique slugs; derive from the group + title and
  # suffix on collision ("edge-city-workshops", "edge-city-workshops-2", ...).
  def generate_track_name(group, title)
    base = "#{group.name}-#{title.to_s.parameterize}".truncate(60, omission: "")
    name = base
    n = 1
    name = "#{base}-#{n += 1}" while Track.exists?(name: name)
    name
  end

  def track_params
    params.require(:track).permit(:group_id, :name, :title, :description, :image_url,
      :is_private, :start_date, :end_date, manager_ids: [])
  end
end
