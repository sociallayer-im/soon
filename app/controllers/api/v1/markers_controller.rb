class Api::V1::MarkersController < Api::BaseController
  # The community map is public.
  skip_before_action :authenticate!, only: %i[index show]
  before_action :authenticate_optional!, only: :index
  before_action :set_marker, only: %i[show update destroy]

  # GET /api/v1/markers?group_id=<TSID or slug>&category=
  # With a group filter the map is browsable anonymously; without one an
  # authenticated caller sees markers across their own groups.
  def index
    scope = Marker.includes(:place, :group, :owner)
    if params[:group_id].present?
      scope = scope.where(group_id: Group.resolve!(params[:group_id]).id)
    elsif current_user
      scope = scope.where(group_id: current_user.groups.select(:id))
    else
      return render_error("group_id is required", status: :unprocessable_entity)
    end
    scope = scope.where(category: params[:category]) if params[:category].present?
    render_collection scope, blueprint: MarkerBlueprint
  end

  def show
    render json: MarkerBlueprint.render(@marker)
  end

  def create
    marker = Marker.new(marker_params.merge(owner: current_user))
    # MarkerPolicy#create?: only group members may pin markers on the map.
    # (A blank/unknown group_id falls through to validation → 422.)
    authorize marker if marker.group

    if marker.save
      render json: MarkerBlueprint.render(marker), status: :created
    else
      render_error(marker.errors.full_messages.join(", "))
    end
  end

  def update
    authorize @marker # owner or group manager
    if @marker.update(marker_params.except(:group_id))
      render json: MarkerBlueprint.render(@marker)
    else
      render_error(@marker.errors.full_messages.join(", "))
    end
  end

  def destroy
    authorize @marker # owner or group manager
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
