class BadgePolicy < ApplicationPolicy
  def own?    = record.owner_id == user&.id
  def update? = record.creator_id == user&.id || own?

  def send?
    if record.badge_class.group
      group_admin?(record.badge_class.group)
    else
      record.creator_id == user&.id
    end
  end
end
