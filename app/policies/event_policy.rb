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
  # A co-host (EventRole role: "manager") can edit the event and gates the
  # same approve/reject/check_in actions this method backs — sails/ granted
  # this to any assigned EventRole regardless of role; narrowed here to
  # "manager" specifically since soon/'s EventRole already distinguishes
  # co-host (manager) from merely-listed speaker (member), and a speaker
  # editing the whole event was never clearly intentional in sails/ either.
  def update?  = owner?(record) || group_admin?(record.group) || event_co_host?(record)
  def destroy? = owner?(record) || group_admin?(record.group)

  # Publishing a pending event is a group-manager review action — owning the
  # event does not let you approve it yourself.
  def approve? = group_admin?(record.group)

  private

  def event_co_host?(event)
    return false unless user

    event.event_roles.exists?(item_type: "User", item_id: user.id, role: "manager")
  end
end
