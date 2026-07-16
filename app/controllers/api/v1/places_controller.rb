class Api::V1::PlacesController < Api::BaseController
  before_action :set_place, only: :show

  def index
    render_collection Place.all, blueprint: PlaceBlueprint
  end

  def show
    render json: PlaceBlueprint.render(@place)
  end

  # POST /api/v1/places — find-or-create by name. Every location-bearing write
  # in the frontend (events, venues, markers) resolves its location to a
  # place_id through here first, so creating an existing name returns the
  # existing record (200) instead of erroring; a new name creates it (201).
  def create
    existing = Place.find_by(name: place_params[:name])
    if existing
      render json: PlaceBlueprint.render(existing)
    else
      place = Place.create!(place_params)
      render json: PlaceBlueprint.render(place), status: :created
    end
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # GET /api/v1/places/search?query= — typeahead over name/address.
  def search
    q = params[:query].to_s.strip
    return render json: [] if q.blank?

    places = Place.where("name ILIKE :q OR address ILIKE :q", q: "%#{Place.sanitize_sql_like(q)}%")
                  .order(:name).limit(20)
    render json: PlaceBlueprint.render(places)
  end

  private

  def set_place
    @place = Place.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def place_params
    params.require(:place).permit(:name, :address, :latitude, :longitude, :description, data: {})
  end
end
