class EventPolicy < ApplicationPolicy
  def index?  = true

  # Draft/archived events are visible only to the owner or a group manager.
  # Public events are visible to anyone; private events to group members.
  def show?
    return owner?(record) || group_admin?(record.group) if %w[draft archived].include?(record.status)
    return true if record.visibility == "public"
    owner?(record) || group_member?(record.group) # private
  end

  # Mirrors the frontend's canPublishEvent logic (seastar-app src/utils/index.ts) —
  # the group's can_publish_event setting, not bare membership, decides who may
  # create an event. Previously this only checked group_member?, so a group set
  # to "everyone" silently 403'd any non-member who the UI told could publish.
  def create?
    case record.group.can_publish_event
    when "everyone" then true
    when "member" then group_member?(record.group)
    else group_admin?(record.group) # "manager" or unset
    end
  end
  # Anyone assigned an EventRole (co-host, speaker, custom host — matched by
  # account or by invite email) can edit the event, mirroring sails/ and the
  # frontend's isEventOperator check. An earlier version gated this on
  # role: "manager", a value that has never existed in the data, which
  # silently revoked every co-host's edit access.
  def update?  = owner?(record) || group_admin?(record.group) || event_co_host?(record)
  def destroy? = owner?(record) || group_admin?(record.group)

  # Publishing a pending event is a group-manager review action — owning the
  # event does not let you approve it yourself.
  def approve? = group_admin?(record.group)

  private

  def event_co_host?(event)
    return false unless user

    scope = event.event_roles.where(item_type: "User", item_id: user.id)
    scope = scope.or(event.event_roles.where(email: user.email)) if user.email.present?
    scope.exists?
  end
end
