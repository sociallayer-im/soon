class Api::V1::MarkersController < Api::BaseController
  before_action :set_marker, only: %i[show update destroy]

  def index
    render_collection Marker.where(group_id: current_user.groups), blueprint: MarkerBlueprint
  end

  def show
    render json: MarkerBlueprint.render(@marker)
  end

  def create
    marker = Marker.new(marker_params.merge(owner: current_user))
    if marker.save
      render json: MarkerBlueprint.render(marker), status: :created
    else
      render_error(marker.errors.full_messages.join(", "))
    end
  end

  def update
    if @marker.update(marker_params)
      render json: MarkerBlueprint.render(@marker)
    else
      render_error(@marker.errors.full_messages.join(", "))
    end
  end

  def destroy
    @marker.destroy
    head :no_content
  end

  private

  def set_marker
    @marker = Marker.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def marker_params
    params.require(:marker).permit(:place_id, :group_id, :category, :pin_image_url,
      :cover_image_url, :title, :about, :link, :status, data: {})
  end
end
