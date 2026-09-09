class EventPolicy < ApplicationPolicy
  def index?  = true

  # Draft/archived events are visible only to the owner or a group manager.
  # normal/open_registration/unlisted are all visible to anyone who has the
  # event's URL — "unlisted" only means excluded from public listings (see
  # Event::VISIBILITIES), the same sense as an unlisted YouTube video, not a
  # membership gate. It used to be, back when this value was called "private";
  # the rename to "unlisted" wasn't matched here until 2026-08-24.
  def show?
    return owner?(record) || group_admin?(record.group) if %w[draft archived].include?(record.status)
    true
  end

  # Whether the current user may join (become a participant in) this event.
  # Gated by the group's can_join_event (manager|member|everyone, default
  # everyone) — unless the event itself is marked open_registration, which
  # bypasses that restriction so a member-only group can still run one event
  # open to everyone.
  def join?
    return true if owner?(record) || group_admin?(record.group)
    return true if record.visibility == "open_registration"

    case record.group.can_join_event
    when "member" then group_member?(record.group)
    when "manager" then false # only admins may join; already allowed above
    else true # "everyone", unset, or unrecognized — unrestricted
    end
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

  # The roles that grant edit access. A whitelist rather than `where.not
  # judge` so the next role added defaults to no power: a judge is listed on
  # the event, not in charge of it (design/HACKATHON_MODULE.md §2.1).
  EDITOR_ROLES = %w[group_host custom_host co_host speaker].freeze

  def event_co_host?(event)
    return false unless user

    roles = event.event_roles.where(role: EDITOR_ROLES)
    scope = roles.where(item_type: "User", item_id: user.id)
    scope = scope.or(roles.where(email: user.email)) if user.email.present?
    scope.exists?
  end
end
