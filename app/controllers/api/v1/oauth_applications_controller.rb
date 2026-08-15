# The developer portal's backend. Any signed-in user may register an app and
# activate it without review (design/OAUTH_PROVIDER_PLAN.md §8), so the guards
# that would normally live in a review step live in the model instead:
# reserved-name rejection, a per-owner cap, and https-only redirect URIs.
class Api::V1::OauthApplicationsController < Api::BaseController
  before_action :set_application, only: %i[show update destroy rotate_secret]

  def index
    apps = OauthApplication.where(owner: current_user).includes(:group, :owner).order(created_at: :desc)
    render json: OauthApplicationBlueprint.render_as_hash(apps)
  end

  def show
    render json: OauthApplicationBlueprint.render_as_hash(@application)
  end

  def create
    if params[:group_id].present?
      group = Group.find(params[:group_id])
      authorize group, :update?, policy_class: GroupPolicy
    end

    app, secret = OauthApplication.create_with_secret(
      application_params.merge(owner: current_user, group_id: params[:group_id].presence)
    )
    # The only two moments this value is ever readable. There is no endpoint
    # that can return it again — rotate_secret issues a new one instead.
    render json: OauthApplicationBlueprint.render_as_hash(app).merge(client_secret: secret), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  def update
    # status is in the permit list on purpose: self-activation is the decision
    # in §8. "disabled" set by the owner is just a pause; only an admin's
    # disable! also burns live tokens.
    @application.update!(application_params)
    render json: OauthApplicationBlueprint.render_as_hash(@application)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  def destroy
    # dependent: :destroy on the token associations means deleting the app also
    # ends every session it holds, which is what a developer expects "delete"
    # to mean.
    @application.destroy!
    render json: { result: "ok" }
  end

  def rotate_secret
    return render json: { error: "Public clients have no secret" }, status: :unprocessable_entity unless @application.confidential?
    secret = @application.rotate_secret!
    render json: OauthApplicationBlueprint.render_as_hash(@application).merge(client_secret: secret)
  end

  private

  def set_application
    @application = OauthApplication.find_by!(id: params[:id], owner_id: current_user.id)
  end

  # A closed allowlist, like every other permit list in soon. `trusted` is
  # absent by design — it skips the consent screen, so no request from any
  # client may set it (same treatment as users.admin). `confidential` is only
  # accepted at creation: flipping it later would either strand a live secret
  # or hand one to a client that has been distributing itself as public.
  def application_params
    permitted = params.require(:application).permit(
      :name, :description, :logo_url, :homepage_url, :status,
      redirect_uris: [], allowed_scopes: []
    )
    if action_name == "create"
      # Cast rather than compare: over HTTP this arrives as the string "false",
      # which is truthy in Ruby, and a client that asked to be public would
      # silently be issued a secret it can only leak.
      raw = params[:application][:confidential]
      permitted[:confidential] = raw.nil? || ActiveModel::Type::Boolean.new.cast(raw) != false
    end
    permitted
  end
end
