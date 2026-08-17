class ReplyPolicy < ApplicationPolicy
  def index? = true

  def show?
    return false unless TopicPolicy.new(user, record.topic).show?
    return true  if !record.flagged?
    author? || manages_group?
  end

  # Replying follows the same tier as posting, and additionally needs the
  # topic to be open.
  def create?
    return false if user.nil?
    return false if record.topic.closed?

    TopicPolicy.new(user, record.topic).create?
  end

  def update?  = author? || manages_group?
  def destroy? = author? || manages_group?
  def flag?    = manages_group?
  def restore? = manages_group?

  private

  # !! rather than a bare && : with no user this returns nil, and the
  # blueprint would ship can_edit: null where the client's type says boolean.
  def author? = !!(user && record.user_id == user.id)

  def manages_group?
    !!GroupPolicy.new(user, record.topic.group).manage?
  end
end
