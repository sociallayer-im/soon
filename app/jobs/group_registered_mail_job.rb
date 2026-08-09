# Tells every platform administrator that a group just registered.
#
# Off the request for the same reason as GroupBroadcastMailJob: the admin list
# is read at delivery time, not at create time, and each admin's mail retries
# on its own. It also means a mail failure can never fail the group creation
# that triggered it — the group exists either way.
class GroupRegisteredMailJob < ApplicationJob
  queue_as :mailers

  def perform(group_id:)
    group = Group.find(group_id)

    User.admin_emails.each do |email|
      GroupMailer.registered(group_id: group.id, recipient: email).deliver_later
    end
  end
end
