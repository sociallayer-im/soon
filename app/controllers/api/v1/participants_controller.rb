class Api::V1::ParticipantsController < Api::BaseController
  before_action :set_event

  # GET /api/v1/events/:event_id/participants
  def index
    render_collection @event.participants.includes(:user), blueprint: ParticipantBlueprint
  end

  # POST /api/v1/events/:event_id/participants
  def create
    participant = @event.participants.new(user: current_user, status: params.dig(:participant, :status) || "attending")
    if participant.save
      render json: ParticipantBlueprint.render(participant), status: :created
    else
      render_error(participant.errors.full_messages.join(", "))
    end
  end

  # PATCH /api/v1/events/:event_id/participants/:id
  def update
    participant = @event.participants.find(params[:id])
    unless participant.user_id == current_user.id
      return render json: { error: "Forbidden" }, status: :forbidden
    end
    if participant.update(status: params.dig(:participant, :status))
      render json: ParticipantBlueprint.render(participant)
    else
      render_error(participant.errors.full_messages.join(", "))
    end
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # DELETE /api/v1/events/:event_id/participants/:id
  def destroy
    participant = @event.participants.find(params[:id])
    unless participant.user_id == current_user.id
      return render json: { error: "Forbidden" }, status: :forbidden
    end
    participant.destroy
    head :no_content
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  private

  def set_event
    @event = Event.find(params[:event_id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end
end
