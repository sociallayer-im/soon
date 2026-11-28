# Only used by the opt-in combined Atlas image. API-only deployments keep their
# original routing. The shared HTML entry must never be cached across releases.
class WebController < ActionController::Base
  def index
    response.headers["Cache-Control"] = "no-store"
    send_file Rails.root.join("web", "index.html"), type: "text/html", disposition: "inline"
  end
end
