class MembershipBlueprint < Blueprinter::Base
  identifier :id

  # admin_notification is only meaningful on an owner/manager row, but it is in
  # the default view rather than a named one so the member roster — the single
  # place the setting is shown and toggled — doesn't need a second request.
  fields :role, :active, :admin_notification, :created_at
  association :user, blueprint: UserBlueprint

  # Which teams this person is in. The roster is fetched whole and filtered in
  # the browser, so the badges and the team filter both read this rather than
  # asking for a second request per member. Callers MUST preload it — see
  # GroupsController; 2407 memberships each resolving their own teams is 2407
  # queries.
  # Ordered the same way the filter chips are (the manager's `sort`, then id),
  # so the same two teams do not appear in one order on one row and another on
  # the next. sort_by on the loaded array rather than an ordered query — the
  # association is preloaded, and re-ordering it in SQL would undo that.
  field :teams do |membership|
    mine = membership.user.teams.select { |t| t.group_id == membership.group_id }
    TeamRefBlueprint.render_as_hash(mine.sort_by { |t| [ -t.sort, t.id ] })
  end

  # For "which groups does this user belong to" listings.
  view :with_group do
    association :group, blueprint: GroupBlueprint
  end
end
