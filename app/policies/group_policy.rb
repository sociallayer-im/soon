class GroupPolicy < ApplicationPolicy
  def index?   = true
  def show?    = true
  def create?  = !user.nil?
  def update?  = manages?(record)
  def destroy? = manages?(record)
  def manage?  = manages?(record)

  # Freezing (deactivating) a group is owner-only — group admins manage
  # content, but only an owner (or a platform admin) can take it offline.
  def freeze?  = user ? (user.platform_admin? || user.memberships.exists?(group: record, role: "owner")) : false

  # Who may view the member roster: members of the group, or a manager.
  def members? = group_member?(record) || manages?(record)

  # Interim design decision (2026-07-29, see soon/design/CHANGELOG.md): a
  # parent-group manager's ONLY capability over a child group is the manager
  # role on one of its members — nothing else (no update/destroy/venue/track/
  # badge-class/invite/pin access, and no teams). Wired into
  # MembershipsController#update, which checks this instead of #manage? when
  # the caller isn't a direct admin. Recorded as a deliberate narrowing, not
  # an oversight — a parent-manager previously had full #manage? over child
  # groups (matching CLAUDE.md's original "Parent-Child Groups" contract);
  # whether to restore broader parent access is intentionally left open for a
  # later product decision, not resolved here.
  #
  # Narrowed again 2026-08-18: it used to be a two-way toggle. Granting the
  # role is still theirs, taking it away is the owner's alone — wherever you
  # stand. See MembershipsController#can_change_role?, and
  # design/PERMISSIONS.md for the whole model in one place.
  def can_assign_manager?
    return false unless record
    return true if user&.platform_admin?
    group_admin?(record) || (record.parent && group_admin?(record.parent))
  end

  private

  # A group is managed by its own admins/owners and by platform admins (who
  # curate/remove popup cities) — NOT by a parent group's manager (see
  # #can_assign_manager? for the one narrow exception that still is).
  def manages?(group)
    return false unless group
    return true if user&.platform_admin?
    group_admin?(group)
  end
end
