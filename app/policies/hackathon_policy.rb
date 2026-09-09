class HackathonPolicy < ApplicationPolicy
  def index? = true

  def show?
    return false if record.flagged? && !(author? || manages_group?)

    record.published? || author? || manages_group?
  end

  # Same tier shape as PollPolicy#create?, read from can_create_hackathon.
  def create?
    return false if user.nil?
    return true  if manages_group?

    case record.group&.can_create_hackathon
    when "manager" then false
    when "member"  then group_member?(record.group)
    else                true
    end
  end

  def update?  = manage?
  def destroy? = manage?
  def publish? = manage?
  def flag?    = manages_group?
  def restore? = manages_group?
  def export?  = manage?

  # Organiser: the creator or a group manager. Everything on the hackathon
  # itself, and on any project in it, keys off this.
  def manage? = author? || manages_group?

  # Who may create a project (design/HACKATHON_MODULE.md §3.2). The
  # participant tier reads the registration event's attending list, so it
  # is false — not an error — once that event is gone.
  def can_submit_project?
    return false if user.nil?
    return true  if manage?

    case record.can_submit_project
    when "participant"
      record.event_id.present? &&
        Participant.exists?(event_id: record.event_id, user_id: user.id, status: "attending")
    when "member" then group_member?(record.group)
    else               true
    end
  end

  def manages_group?
    !!GroupPolicy.new(user, record.group).manage?
  end

  private

  def author? = !!(user && record.user_id == user.id)
end
