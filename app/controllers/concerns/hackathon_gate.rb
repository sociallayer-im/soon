# The group-level hackathon switch, checked against the record a request
# names rather than a ?group_id parameter — the same lesson as PollGate and
# DiscussionGate. 404, not 403, for the same reason.
module HackathonGate
  extend ActiveSupport::Concern

  private

  def hackathon_enabled? = ENV["HACKATHON_ENABLED"] == "true"

  def require_hackathon_enabled!
    render_not_found unless hackathon_enabled?
  end

  def require_group_hackathon!(group)
    render_not_found unless group&.hackathon_enabled?
    group&.hackathon_enabled?
  end
end
