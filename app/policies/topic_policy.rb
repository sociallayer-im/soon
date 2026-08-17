class TopicPolicy < ApplicationPolicy
  def index? = true

  # A topic is readable when its board is readable and it is not hidden from
  # this particular reader. Both halves are needed; see DISCUSSION_PLAN 1.2/1.3.
  def show?
    return false unless record.category.visible_to?(user)
    return true  if !record.flagged?
    author? || manages_group?
  end

  # Posting needs three things to line up: the board must be visible, the
  # group's can_post_topic tier must admit this person, and the board's own
  # visibility narrows it further — a manager-only board takes posts from
  # managers even when the group says "everyone".
  def create?
    return false if user.nil?
    return false unless record.category&.visible_to?(user)
    return true  if manages_group?

    case record.group&.can_post_topic
    when "manager"  then false
    when "member"   then group_member?(record.group)
    else                 true
    end && posting_allowed_by_board?
  end

  def update?  = author? || manages_group?
  def destroy? = author? || manages_group?

  # Moderation is manager-only. Closing is the exception: an author may close
  # their own thread.
  def close?   = author? || manages_group?
  def pin?     = manages_group?
  def flag?    = manages_group?
  def restore? = manages_group?
  def move?    = manages_group?

  private

  # !! rather than a bare && : with no user this returns nil, and the
  # blueprint would ship can_edit: null where the client's type says boolean.
  def author? = !!(user && record.user_id == user.id)

  def manages_group?
    !!GroupPolicy.new(user, record.group).manage?
  end

  def posting_allowed_by_board?
    record.category.visibility != "manager"
  end
end
