class Api::BaseController < ActionController::API
  include Pundit::Authorization

  before_action :authenticate!

  rescue_from Pundit::NotAuthorizedError do
    render json: { error: "Forbidden" }, status: :forbidden
  end

  rescue_from ActiveRecord::RecordNotFound do
    render_not_found
  end

  PAGY_DEFAULT_LIMIT = 20

  private

  def authenticate!
    token = request.headers["Authorization"]&.split(" ")&.last
    payload = JwtService.decode(token)
    @current_user = User.find(payload["user_id"])
  rescue JwtService::Error, ActiveRecord::RecordNotFound
    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  def current_user
    @current_user
  end

  def render_collection(scope, blueprint:, **blueprint_opts)
    pagy = Pagy::Offset.new(
      count: scope.count,
      page: params.fetch(:page, 1).to_i,
      limit: params.fetch(:limit, PAGY_DEFAULT_LIMIT).to_i
    )
    records = pagy.records(scope)
    render json: {
      data: JSON.parse(blueprint.render(records, **blueprint_opts)),
      meta: pagy_metadata(pagy)
    }
  end

  def pagy_metadata(pagy)
    {
      page:        pagy.page,
      limit:       pagy.limit,
      total:       pagy.count,
      total_pages: pagy.last,
      next_page:   pagy.next,
      prev_page:   pagy.previous
    }
  end

  def render_error(message, status: :unprocessable_entity)
    render json: { error: message }, status: status
  end

  def render_not_found
    render json: { error: "Not found" }, status: :not_found
  end
end
