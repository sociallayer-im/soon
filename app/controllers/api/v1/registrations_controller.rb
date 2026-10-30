class Api::V1::RegistrationsController < Api::BaseController
  def index
    if ActiveModel::Type::Boolean.new.cast(params[:team])
      scope = Event.team_for(current_user).visible_to(current_user).where(status: %w[published closed]).includes(:group, :place, :venue, :owner, :track).order(start_time: :desc, id: :desc)
      return render_collection scope, blueprint: EventBlueprint, event_team_ids: scope.pluck(:id).to_set, viewer_id: current_user.id
    end
    scope = current_user.participants.includes(:user, event: [:group, :place, :venue, :owner, :track]).order(registered_at: :desc, id: :desc)
    render_collection scope, blueprint: RegistrationBlueprint, own: true
  end
end
