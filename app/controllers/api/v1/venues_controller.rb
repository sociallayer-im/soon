class Api::V1::VenuesController < Api::BaseController
  before_action :set_venue, only: %i[show update destroy set_availability]

  def index
    render_collection Venue.where(archived: false), blueprint: VenueBlueprint
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
      :place_id, :require_approval, :group_id, amenities: [], tags: [], image_urls: [], track_ids: [])
  end
end
