# Stamps closed_at on polls past their deadline and tells the author and
# voters once. Reading `closed?` is derived from close_at so the display never
# waits on this; the job exists because a notification is a side effect, and
# nothing fires side effects without a request unless something sweeps.
# Idempotent: pending_close excludes anything already stamped.
class PollAutoCloseJob < ApplicationJob
  queue_as :mailers

  def perform
    Poll.pending_close.find_each do |poll|
      # The stamp is the claim; a concurrent sweep updating zero rows notifies
      # nobody.
      next unless Poll.where(id: poll.id, closed_at: nil).update_all(closed_at: poll.close_at, updated_at: Time.current) == 1

      notify(poll)
    rescue => e
      Rails.error.report(e, handled: true, context: { poll_id: poll.id })
    end
  end

  private

  def notify(poll)
    user_ids = poll.poll_votes.distinct.pluck(:user_id) | [ poll.user_id ]
    User.where(id: user_ids).where.not(email: [ nil, "" ]).distinct.pluck(:email).each do |email|
      PollMailer.closed(poll_id: poll.id, recipient: email).deliver_later
    end
  end
end
