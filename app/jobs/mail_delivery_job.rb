# Every `deliver_later` goes through this job (wired up by
# `config.action_mailer.delivery_job` in config/application.rb).
#
# Before GoodJob these deliveries ran on Rails' in-memory :async adapter, where
# a failed send was simply gone. Now the job is a database row, so it is worth
# giving it a real failure policy rather than letting one flaky HTTP call to
# Resend drop a sign-in invite on the floor.
class MailDeliveryJob < ActionMailer::MailDeliveryJob
  queue_as :mailers

  # ActiveSupport::Rescuable matches handlers last-registered-first, so the
  # broad Resend::Error rule has to come BEFORE the narrower ones below or it
  # would swallow them.
  retry_on Resend::Error, wait: :polynomially_longer, attempts: 5

  # Resend maps 429 to this and tells us when to come back; give it more room
  # than a generic failure since the send is fine, we were just too fast.
  retry_on Resend::Error::RateLimitExceededError, wait: :polynomially_longer, attempts: 8

  # The transport itself failing (DNS, TLS, a hung socket) is the most common
  # transient cause and never reaches a Resend:: error class.
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
    Net::OpenTimeout, Net::ReadTimeout, SocketError,
    wait: :polynomially_longer, attempts: 5

  # The mailers look their subject up by id (`Event.find(event_id)`), so a
  # record deleted between enqueue and execution raises here. There is nothing
  # left to send and no amount of retrying brings it back — GoodJob keeps the
  # discarded row with its error for anyone asking "why didn't that go out?".
  discard_on ActiveRecord::RecordNotFound
  discard_on ActiveJob::DeserializationError
end
