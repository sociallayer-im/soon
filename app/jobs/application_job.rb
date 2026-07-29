class ApplicationJob < ActiveJob::Base
  # A row-level deadlock is by definition transient — the loser just needs to
  # go again.
  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 3

  # Jobs here take ids and look records up themselves, so a record deleted
  # between enqueue and execution surfaces as RecordNotFound rather than a
  # deserialization failure. Either way there is no work left to do.
  discard_on ActiveRecord::RecordNotFound
  discard_on ActiveJob::DeserializationError
end
