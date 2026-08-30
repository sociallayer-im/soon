# Tells every platform administrator that a withdrawal was just requested.
#
# Off the request for the same reason as GroupRegisteredMailJob: the admin
# list is read at delivery time, each admin's mail retries on its own, and a
# mail failure can never fail the withdrawal request that triggered it.
class WithdrawalRequestedMailJob < ApplicationJob
  queue_as :mailers

  def perform(withdrawal_id:)
    withdrawal = Withdrawal.find(withdrawal_id)

    User.admin_emails.each do |email|
      GroupMailer.withdrawal_requested(withdrawal_id: withdrawal.id, recipient: email).deliver_later
    end
  end
end
