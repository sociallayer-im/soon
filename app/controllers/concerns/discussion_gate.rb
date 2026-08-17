# The two switches that decide whether the discussion boards exist at all.
#
# DISCUSSION_ENABLED is the deployment's, checked by a before_action. This
# concern is the second one — the group's own `discussion_enabled` — which has
# to be checked against whichever record the request names, not just against a
# ?group_id parameter. Without that, turning a group's forum off leaves every
# existing topic reachable by its id: readable, editable and deletable.
#
# 404 rather than 403, like every other invisibility in this feature: a group
# that has switched its forum off has no forum, it does not have a forbidden
# one.
module DiscussionGate
  extend ActiveSupport::Concern

  private

  def require_group_discussion!(group)
    render_not_found unless group&.discussion_enabled?
    group&.discussion_enabled?
  end
end
