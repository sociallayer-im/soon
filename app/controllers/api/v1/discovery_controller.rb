class Api::V1::DiscoveryController < Api::BaseController
  skip_before_action :authenticate!
  before_action :authenticate_optional!
  before_action -> { response.headers["Cache-Control"] = "private, no-store" }
  rescue_from DiscoveryFeed::InvalidCursor do
    render_error("推荐列表已过期或不匹配，请刷新重试。")
  end

  def home = render(json: feed.home)
  def community = render(json: feed.community(scope: params[:scope].presence || "discover"))
  def index
    render json: feed.page(params[:kind].to_s, scope: params[:scope].presence || "discover", cursor: params[:cursor], limit: params[:limit].presence || 20)
  end

  private
  def feed
    city = params.key?(:city) ? params[:city].to_s : "上海"
    raise DiscoveryFeed::InvalidCursor if city.length > 100
    @feed ||= DiscoveryFeed.new(user: current_user, city: city)
  end
end
