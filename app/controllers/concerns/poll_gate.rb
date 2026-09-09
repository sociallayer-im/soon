# The group-level poll switch, checked against the record a request names
# rather than a ?group_id parameter — the same lesson as DiscussionGate:
# otherwise turning polls off leaves every existing poll reachable by id.
# 404, not 403, for the same reason.
module PollGate
  extend ActiveSupport::Concern

  private

  def poll_enabled? = ENV["POLL_ENABLED"] == "true"

  def require_poll_enabled!
    render_not_found unless poll_enabled?
  end

  def require_group_poll!(group)
    render_not_found unless group&.poll_enabled?
    group&.poll_enabled?
  end
end
