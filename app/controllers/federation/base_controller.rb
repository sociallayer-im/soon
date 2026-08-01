module Federation
  # Root-level federation endpoints (not /api/v1): no JWT, no CORS coupling.
  # Everything 404s while FEDERATION_ENABLED is off — that env var is the
  # rollout and rollback lever.
  class BaseController < ActionController::API
    before_action :require_federation!

    private

    def require_federation!
      head :not_found unless Federation.enabled?
    end

    def ap_request?
      accept = request.headers["Accept"].to_s
      accept.include?("application/activity+json") || accept.include?("application/ld+json")
    end

    def render_ap(doc, status: :ok)
      response.headers["Cache-Control"] = "public, max-age=60"
      render json: doc, status: status, content_type: "application/activity+json"
    end

    def web_url
      ENV.fetch("WEB_URL", "https://app.sola.day")
    end
  end
end
