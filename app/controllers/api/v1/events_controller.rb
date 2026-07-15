class Api::V1::EventsController < Api::BaseController
  before_action :set_event, only: %i[show update destroy]

  def index
    render_collection Event.where(group_id: current_user.groups), blueprint: EventBlueprint
  end

  def show
    render json: EventBlueprint.render(@event)
  end

  def create
    event = Event.new(event_params.merge(owner: current_user))
    authorize event
    if event.save
      render json: EventBlueprint.render(event), status: :created
    else
      render_error(event.errors.full_messages.join(", "))
    end
  end

  def update
    authorize @event
    if @event.update(event_params)
      render json: EventBlueprint.render(@event)
    else
      render_error(@event.errors.full_messages.join(", "))
    end
  end

  def destroy
    authorize @event
    @event.destroy
    head :no_content
  end

  private

  def set_event
    @event = Event.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def event_params
    params.require(:event).permit(:title, :content, :start_time, :end_time, :timezone,
      :status, :visibility, :group_id, :place_id, :venue_id, :track_id, :meeting_url,
      :external_url, :max_participant, :require_approval, :category, :kind,
      tags: [], requirement_tags: [])
  end
end
