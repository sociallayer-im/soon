# Platform-admin view over every registered application.
#
# semi's equivalent endpoint had no authentication at all — anyone could
# enumerate every application and its owner. Here every action is gated on
# users.admin, which is settable in the database only.
#
# With no registration review, `disable` is the platform's only lever against
# an app already in the wild, so it burns live tokens rather than merely
# blocking new authorizations.
class Api::V1::OauthAdminApplicationsController < Api::BaseController
  before_action :require_platform_admin!

  def index
    apps = OauthApplication.includes(:owner, :group).order(created_at: :desc)
    apps = apps.where(status: params[:status]) if params[:status].present?
    if params[:q].present?
      q = "%#{params[:q]}%"
      apps = apps.where("oauth_applications.name ILIKE ? OR oauth_applications.client_id ILIKE ?", q, q)
    end
    render_collection(apps, blueprint: OauthApplicationBlueprint, view: :admin)
  end

  def show
    render json: OauthApplicationBlueprint.render_as_hash(application, view: :admin)
  end

  # Mark an application as reviewed by the platform, which is what the consent
  # screen surfaces to the user. Purely informational — it grants nothing.
  def review
    # Cast: params[:reviewed] is the string "false" over HTTP, which is truthy.
    unreview = params.key?(:reviewed) && ActiveModel::Type::Boolean.new.cast(params[:reviewed]) == false
    application.update!(reviewed_at: unreview ? nil : Time.current)
    render json: OauthApplicationBlueprint.render_as_hash(application, view: :admin)
  end

  def disable
    application.disable!
    render json: OauthApplicationBlueprint.render_as_hash(application, view: :admin)
  end

  private

  def application
    @application ||= OauthApplication.find(params[:id])
  end

  def require_platform_admin!
    render json: { error: "Forbidden" }, status: :forbidden unless current_user&.platform_admin?
  end
end
