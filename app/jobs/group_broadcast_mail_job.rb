# A manager's broadcast to every active member of a group.
#
# The controller used to walk the membership list and enqueue one delivery per
# member inline, so a 2,000-member group meant 2,000 job inserts before the
# request could respond. This job moves that fan-out off the request; each
# recipient still gets its own MailDeliveryJob, so one bad address retries (or
# is discarded) on its own instead of taking the rest of the broadcast with it.
class GroupBroadcastMailJob < ApplicationJob
  queue_as :mailers

  def perform(group_id:, subject:, content:)
    group = Group.find(group_id)

    group.member_emails.each do |email|
      GroupMailer.member_broadcast(group_id: group.id, subject: subject,
        content: content, recipient: email).deliver_later
    end
  end
end
