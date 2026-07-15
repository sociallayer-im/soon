class Api::V1::PlacesController < Api::BaseController
  before_action :set_place, only: :show

  def index
    render_collection Place.all, blueprint: PlaceBlueprint
  end

  def show
    render json: PlaceBlueprint.render(@place)
  end

  private

  def set_place
    @place = Place.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end
end
