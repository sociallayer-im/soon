class Api::V1::RegistrationsController < Api::BaseController
  def index
    scope = current_user.participants.includes(:user, event: [:group, :place, :venue, :owner, :track]).order(registered_at: :desc, id: :desc)
    render_collection scope, blueprint: RegistrationBlueprint, own: true
  end
end
