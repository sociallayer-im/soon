class MembershipBlueprint < Blueprinter::Base
  identifier :id

  # admin_notification is only meaningful on an owner/manager row, but it is in
  # the default view rather than a named one so the member roster — the single
  # place the setting is shown and toggled — doesn't need a second request.
  # expires_at is nil for a permanent membership (managers/owners, and plain
  # group-ticket grants) — only a membership_card purchase ever sets it.
  fields :role, :active, :admin_notification, :created_at, :expires_at
  association :user, blueprint: UserBlueprint

  # Which teams this person is in, within this group.
  #
  # The roster is a public endpoint, and a team name can be as revealing as
  # its membership — so a team travels with the roster only if it is marked
  # is_public. Members of the group see all of them; `member_group_ids` is the
  # set of groups the viewer belongs to, resolved once per request by the
  # controller rather than per row.
  #
  # Callers MUST preload user: :teams — 2407 memberships each resolving their
  # own teams is 2407 queries (see GroupBlueprint's note on that number).
  #
  # Ordered the same way the filter chips are (the manager's `sort`, then id),
  # so the same two teams do not appear in one order on one row and the
  # reverse on the next.
  field :teams do |membership, options|
    mine = membership.user.teams.select { |t| t.group_id == membership.group_id }
    viewer = options[:member_group_ids]
    sees_all = viewer == :all || viewer&.include?(membership.group_id)
    mine = mine.select(&:is_public) unless sees_all
    TeamRefBlueprint.render_as_hash(mine.sort_by { |t| [ -t.sort, t.id ] })
  end

  # For "which groups does this user belong to" listings.
  view :with_group do
    association :group, blueprint: GroupBlueprint
  end
end
