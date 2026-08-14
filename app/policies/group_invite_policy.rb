class GroupInvitePolicy < ApplicationPolicy
  def accept? = group_admin?(record.group)
  def revoke? = record.sender_id == user&.id || group_admin?(record.group)
  # The recipient may also cancel/decline an invite addressed to them — an
  # email invite (matched by email) or a self-service join request (matched
  # by receiver_id, since request_invite sets that immediately, unlike a sent
  # invite which only gets receiver_id on acceptance).
  def cancel? = revoke? || recipient?

  # The invite-preview page (/invite/:id) needs to render an invite before its
  # recipient has necessarily accepted anything. Sender/group admin/matched
  # recipient can always view it; a "code" invite is reusable by design (its
  # whole point is that an unknown future joiner opens the link), so it's
  # viewable by any authenticated user who has the (effectively unguessable
  # TSID) link — same trust boundary as accept_with_code already assumes.
  def view? = revoke? || recipient? || record.receiver_address_type == "code"

  private

  def recipient?
    return true if record.receiver_id.present? && record.receiver_id == user&.id
    return true if record.receiver_address_type == "email" && record.receiver_address == user&.email
    record.receiver_address_type == "phone" && record.receiver_address == user&.phone
  end
end
