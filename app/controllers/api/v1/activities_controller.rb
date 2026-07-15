class Api::V1::ActivitiesController < Api::BaseController
  # GET /api/v1/activities
  def index
    render_collection Activity.for_receiver(current_user).includes(:initiator).order(created_at: :desc), blueprint: ActivityBlueprint
  end

  # POST /api/v1/activities/mark_read
  def mark_read
    activities = Activity.where(id: params[:ids])
    if activities.any? { |a| a.receiver_id != current_user.id }
      return render_error("not authorized", status: :forbidden)
    end

    activities.update_all(has_read: true)
    render json: { result: "ok" }
  end
end
