class Api::V1::EventRolesController < Api::BaseController
  before_action :set_event

  # GET /api/v1/events/:event_id/event_roles
  def index
    authorize @event, :show?
    render json: EventRoleBlueprint.render(@event.event_roles)
  end

  # POST /api/v1/events/:event_id/event_roles
  def create
    authorize_event_manager!
    return if performed?
    return render_error("item_type must be User or Group") unless valid_item_type?

    role = @event.event_roles.new(event_role_params)
    change_roles { role.save! }
    render json: EventRoleBlueprint.render(role), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # PATCH /api/v1/events/:event_id/event_roles/:id
  def update
    authorize_event_manager!
    return if performed?
    return render_error("item_type must be User or Group") unless valid_item_type?

    role = @event.event_roles.find(params[:id])
    change_roles { role.update!(event_role_params) }
    render json: EventRoleBlueprint.render(role)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # DELETE /api/v1/events/:event_id/event_roles/:id
  def destroy
    authorize_event_manager!
    return if performed?

    role = @event.event_roles.find(params[:id])
    change_roles { role.destroy! }
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

  def authorize_event_manager!
    authorize @event, :update?
  end

  def change_roles
    @event.with_lock do
      authorize @event, :update?
      before = SiteNotifications.role_links(@event)
      yield
      SiteNotifications.roles_changed(@event, before, actor: current_user)
    end
  end

  def event_role_params
    params.require(:event_role).permit(:item_id, :item_type, :role, :email, :display_name, :image_url)
  end

  # Guards against invalid item_type values before they ever reach the model — an
  # unresolvable polymorphic type (e.g. "widget") makes Rails raise a raw NameError
  # deep inside the uniqueness validator's association resolution instead of a clean
  # validation error, so this has to be checked before construction, not via `valid?`.
  def valid_item_type?
    params.dig(:event_role, :item_type).blank? || %w(User Group).include?(params.dig(:event_role, :item_type))
  end
end
