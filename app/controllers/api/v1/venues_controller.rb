class Api::V1::VenuesController < Api::BaseController
  before_action :set_venue, only: :show

  def index
    render_collection Venue.all, blueprint: VenueBlueprint
  end

  def show
    render json: VenueBlueprint.render(@venue)
  end

  private

  def set_venue
    @venue = Venue.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end
end
