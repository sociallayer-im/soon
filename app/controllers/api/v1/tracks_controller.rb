class Api::V1::TracksController < Api::BaseController
  before_action :set_track, only: :show

  def index
    render_collection Track.all, blueprint: TrackBlueprint
  end

  def show
    render json: TrackBlueprint.render(@track)
  end

  private

  def set_track
    @track = Track.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end
end
