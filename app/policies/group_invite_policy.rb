class GroupInvitePolicy < ApplicationPolicy
  def accept? = group_admin?(record.group)
  def revoke? = record.sender_id == user&.id || group_admin?(record.group)
  def cancel? = revoke?
end
