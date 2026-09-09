class PollPolicy < ApplicationPolicy
  def index? = true

  def show?
    return true if !record.flagged?
    author? || manages_group?
  end

  # Same tier shape as TopicPolicy#create?, read from can_create_poll.
  def create?
    return false if user.nil?
    return true  if manages_group?

    case record.group&.can_create_poll
    when "manager" then false
    when "member"  then group_member?(record.group)
    else                true
    end
  end

  def update?  = author? || manages_group?
  def destroy? = author? || manages_group?
  def close?   = author? || manages_group?
  def flag?    = manages_group?
  def restore? = manages_group?

  # Looser than create: while the poll is open, its group's managers and
  # anyone the poll names as eligible may vote — by default, the group's
  # members; otherwise members of the listed groups or teams.
  def vote?
    return false if user.nil?
    return false if record.closed?
    return true  if manages_group?

    eligible?
  end

  def eligible?
    return false if user.nil?
    return group_member?(record.group) if record.eligible_group_ids.empty? && record.eligible_team_ids.empty?

    user.memberships.exists?(group_id: record.eligible_group_ids) ||
      user.team_memberships.exists?(team_id: record.eligible_team_ids)
  end

  # The three visibility axes (design/POLL_MODULE.md §2.4). Managers are a
  # hard exception on all three — they are who audits a poll.
  def can_see_results?
    return manages_group? if record.results == "manager_only"
    return true           if record.results == "always"
    return record.closed? if record.results == "on_close"

    manages_group? || record.closed? || record.voted_by?(user)
  end

  # Who voted, not what they chose.
  def can_see_participants?
    return true if manages_group?

    record.visibility.in?(%w[public participants]) && can_see_results?
  end

  # What each person chose.
  def can_see_choices?
    return true if manages_group?

    record.visibility == "public" && can_see_results?
  end

  def manages_group?
    !!GroupPolicy.new(user, record.group).manage?
  end

  private

  def author? = !!(user && record.user_id == user.id)
end
