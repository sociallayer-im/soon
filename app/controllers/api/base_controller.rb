class Api::BaseController < ActionController::API
  include Pundit::Authorization

  before_action :authenticate!
  around_action :with_notification_actor

  def with_notification_actor(&block)
    NotificationContext.set(actor: current_user, &block)
  end

  rescue_from Pundit::NotAuthorizedError do
    render json: { error: "Forbidden" }, status: :forbidden
  end

  rescue_from ActiveRecord::RecordNotFound do
    render_not_found
  end

  PAGY_DEFAULT_LIMIT = 20
  # No caller-supplied ?limit needs to exceed this — the highest legitimate
  # frontend request is 400 (the schedule-grid view, which renders a whole
  # date-bounded range and can't paginate a visual calendar). Without a cap,
  # one oversized request can pull a group's entire event history (with full
  # nested associations) in one response; this bounds the damage regardless
  # of who's asking, with headroom above every current caller.
  PAGY_MAX_LIMIT = 500

  private

  # Deployment gate for the whole Stripe feature (design/PAYMENTS_PLAN.md
  # decision #13): SG sets STRIPE_ENABLED=true, CN leaves it unset. Gated
  # controllers 404 as if the routes didn't exist.
  def stripe_enabled? = ENV["STRIPE_ENABLED"] == "true"

  def require_stripe_enabled!
    render_not_found unless stripe_enabled?
  end

  # The mirror-image gate for WeChat Pay: CN sets WECHAT_PAY_ENABLED=true, SG
  # leaves it unset (design/WECHAT_INTEGRATION.md §3.1). Note this is only the
  # deployment switch — a deployment can have it on and still have no merchant
  # installed, which WechatPaySetting.platform_default is what answers.
  def wechat_pay_enabled? = ENV["WECHAT_PAY_ENABLED"] == "true"

  # Feature flag for SMS phone sign-in. Phone completion is a client flow,
  # not a prerequisite for API business operations or setting a username.
  def phone_login_enabled? = ENV["PHONE_LOGIN_ENABLED"] == "true"

  # The discussion boards are off unless a deployment turns them on. Gated
  # endpoints 404 rather than 403: a feature that has not shipped should look
  # like it does not exist, the same as the phone-auth routes.
  def discussion_enabled? = ENV["DISCUSSION_ENABLED"] == "true"

  def require_discussion_enabled!
    render_not_found unless discussion_enabled?
  end

  def require_wechat_pay_enabled!
    render_not_found unless wechat_pay_enabled?
  end

  def authenticate!
    payload = JwtService.decode(bearer_token)
    @current_user = user_from_payload(payload) or raise ActiveRecord::RecordNotFound
  rescue JwtService::Error, ActiveRecord::RecordNotFound
    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  # For public endpoints that personalize when a token IS present (e.g. event
  # lists with attendance flags): sets current_user on a valid token, stays
  # anonymous otherwise — never 401s. Pair with skip_before_action :authenticate!.
  def authenticate_optional!
    token = bearer_token
    return if token.blank?
    @current_user = user_from_payload(JwtService.decode(token))
  rescue JwtService::Error
    @current_user = nil
  end

  def bearer_token
    request.headers["Authorization"]&.split(" ")&.last
  end

  # Standard HTTP caching (browser + any CDN in front, e.g. Cloudflare) for
  # public GETs that personalize when a token is present — NOT Next.js's own
  # fetch cache, which the frontend deliberately avoids relying on. Only sets
  # Cache-Control when the request is anonymous: an authenticated response
  # carries per-user fields (is_attending/is_starred/...) and a CDN cache is
  # shared across users, so caching it would leak one user's flags to another.
  # The groups this caller belongs to, as a Set, resolved once. Blueprints use
  # it to decide whether to render a group's private team badges; doing it per
  # membership row would be one query per member.
  def member_group_ids
    @member_group_ids ||= if current_user.nil?
      Set.new
    elsif current_user.platform_admin?
      # Consistent with Category.visible_to, which returns everything to a
      # platform admin. Being the only surface that hides something from them
      # would be the surprise, not the other way round.
      :all
    else
      current_user.memberships.pluck(:group_id).to_set
    end
  end

  def cache_when_anonymous!(max_age:)
    return if current_user
    response.headers["Cache-Control"] = "public, max-age=#{max_age}"
  end

  # soon mints {"user_id" => <tsid>}. The legacy sails backend minted
  # {"id" => <integer profile id>} with no `exp`, and those tokens are still in
  # users' browsers at cutover — without this fallback every signed-in user is
  # logged out the moment api.sola.day switches over. `users.ref_id` holds the
  # legacy integer id (populated by script/migrate_from_sails.rb) and carries a
  # partial index. Remove once legacy tokens have aged out.
  def user_from_payload(payload)
    if (id = payload["user_id"]).present?
      User.find_by(id: id, active: true)
    elsif (legacy_id = payload["id"]).present?
      User.find_by(ref_id: legacy_id.to_s, active: true)
    end
  end

  def current_user
    @current_user
  end

  # Opt-in keyset pagination. The timestamp and id are both required so rows
  # sharing a timestamp cannot be skipped. Existing page-based clients remain unchanged.
  def render_newest_cursor(scope, blueprint:, **blueprint_opts)
    limit = params.fetch(:limit, PAGY_DEFAULT_LIMIT).to_i.clamp(1, PAGY_MAX_LIMIT)
    cursor = params[:cursor].to_s
    unless cursor == "start"
      begin
        payload = JSON.parse(Base64.urlsafe_decode64(cursor))
        raise ArgumentError unless payload.is_a?(Hash) && payload["created_at"].is_a?(String)
        time = Time.iso8601(payload.fetch("created_at"))
        id = payload.fetch("id")
        raise ArgumentError unless id.is_a?(String) && id.length.between?(1, 128)
      rescue ArgumentError, KeyError, TypeError, JSON::ParserError
        return render_error("invalid cursor")
      end
      table = scope.klass.arel_table
      scope = scope.where(table[:created_at].lt(time).or(table[:created_at].eq(time).and(table[:id].lt(id))))
    end
    rows = scope.reorder(created_at: :desc, id: :desc).limit(limit + 1).to_a
    has_more = rows.length > limit
    records = rows.first(limit)
    last = records.last
    next_cursor = if has_more && last
      Base64.urlsafe_encode64({created_at: last.created_at.iso8601(6), id: last.id}.to_json, padding: false)
    end
    render json: {data: JSON.parse(blueprint.render(records, **blueprint_opts)), meta: {limit: limit, next_cursor: next_cursor}}
  end

  def render_collection(scope, blueprint:, **blueprint_opts)
    limit = params.fetch(:limit, PAGY_DEFAULT_LIMIT).to_i
    limit = PAGY_DEFAULT_LIMIT if limit <= 0
    pagy = Pagy::Offset.new(
      count: scope.count,
      page: params.fetch(:page, 1).to_i,
      limit: [ limit, PAGY_MAX_LIMIT ].min
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
