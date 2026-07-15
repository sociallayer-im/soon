class BadgeClassPolicy < ApplicationPolicy
  def update? = send?
  def manage? = send?

  def send?
    if record.group_id && record.can_send_badge == "group_member_send"
      group_member?(record.group)
    elsif record.group_id
      group_admin?(record.group)
    else
      record.creator_id == user&.id
    end
  end
end
