class Api::V1::VenuesController < Api::BaseController
  # Venues are public information — they appear on public event pages, and
  # EventBlueprint deliberately embeds only VenueRefBlueprint (id + name), so
  # every caller that needs capacity/about/amenities/availability fetches the
  # venue by id. The SDK's getVenueDetailById sends no token, so without this
  # skip #show 401s for everyone, including managers on the venue edit page
  # (the page's loader gets null back and crashes with a 500).
  #
  # #index stays authenticated: nothing fetches it anonymously — a group's
  # venue list arrives embedded in GroupBlueprint :detail.
  skip_before_action :authenticate!, only: %i[show]
  before_action :set_venue, only: %i[show update destroy set_availability conflict]

  def index
    scope = Venue.where(archived: false)
    scope = scope.where(group_id: Group.resolve!(params[:group_id]).id) if params[:group_id].present?
    render_collection scope, blueprint: VenueBlueprint
  end

  def show
    render json: VenueBlueprint.render(@venue, view: :with_availability)
  end

  def create
    group = Group.find_by(id: venue_params[:group_id])
    return render_not_found unless group
    authorize group, :manage?, policy_class: GroupPolicy

    venue = group.venues.new(venue_params.except(:group_id).merge(owner: current_user))
    if venue.save
      render json: VenueBlueprint.render(venue), status: :created
    else
      render_error(venue.errors.full_messages.join(", "))
    end
  end

  def update
    authorize @venue.group, :manage?, policy_class: GroupPolicy
    if @venue.update(venue_params.except(:group_id))
      render json: VenueBlueprint.render(@venue)
    else
      render_error(@venue.errors.full_messages.join(", "))
    end
  end

  # Soft delete: keep the row (events still reference it) and just archive it.
  def destroy
    authorize @venue.group, :manage?, policy_class: GroupPolicy
    @venue.update(archived: true)
    head :no_content
  end

  # GET /api/v1/venues/:id/conflict — the first event that would clash with the
  # given window (used by the event editor to warn before submitting). Pass
  # exclude_event_id when editing an existing booking.
  def conflict
    start_time = Time.zone.parse(params[:start_time].to_s) rescue nil
    end_time   = Time.zone.parse(params[:end_time].to_s) rescue nil
    return render_error("invalid start_time/end_time") unless start_time && end_time

    overlap = @venue.events.where("start_time < ? AND end_time > ?", end_time, start_time)
                    .where.not(status: "cancelled")
    overlap = overlap.where.not(id: params[:exclude_event_id]) if params[:exclude_event_id].present?
    event = overlap.order(:start_time).first
    render json: { event: event && JSON.parse(EventBlueprint.render(event)) }
  end

  # POST /api/v1/venues/:id/availability — replaces the venue's availability set.
  def set_availability
    authorize @venue.group, :manage?, policy_class: GroupPolicy

    @venue.availabilities.destroy_all
    Array(params[:availabilities]).each do |a|
      @venue.availabilities.create!(
        day: a[:day].presence, day_of_week: a[:day_of_week].presence,
        intervals: a[:intervals] || [], role_required: a[:role_required]
      )
    end
    render json: VenueBlueprint.render(@venue.reload, view: :with_availability)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  private

  def set_venue
    @venue = Venue.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def venue_params
    params.require(:venue).permit(:name, :capacity, :website, :about, :featured_image_url,
      :place_id, :require_approval, :group_id, :start_date, :end_date,
      amenities: [], tags: [], image_urls: [], track_ids: [])
  end
end
