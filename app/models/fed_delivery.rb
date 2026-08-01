# One row = one signed POST owed to one inbox. Written in the same
# transaction as the business change (outbox pattern), drained by the
# sweeper under a rate cap — never delivered inline
# (design/FEDERATION_PLAN.md §2.6, design/FEDERATION_TEST_PLAN.md §2).
class FedDelivery < ApplicationRecord
  STATUSES = %w[pending delivering delivered failed_permanent].freeze
  MAX_ATTEMPTS = 10
  # Mastodon semantics: these response codes are retryable, every other 4xx
  # (and 501) is permanent.
  RETRYABLE_HTTP = [401, 408, 429].freeze

  validates :status, inclusion: {in: STATUSES}
  validates :inbox_url, presence: true
  validates :payload, presence: true

  scope :due, -> {
    where(status: "pending").where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
  }

  def self.retryable_status?(http_status)
    return true if http_status.nil? # transport error, no response
    return false if http_status == 501
    return true if RETRYABLE_HTTP.include?(http_status)
    !(400..499).cover?(http_status)
  end

  def mark_result!(http_status, error: nil)
    if http_status && (200..299).cover?(http_status)
      update!(status: "delivered", last_error: nil)
    elsif !self.class.retryable_status?(http_status)
      update!(status: "failed_permanent", last_error: error || "HTTP #{http_status}")
    elsif attempts >= MAX_ATTEMPTS
      update!(status: "failed_permanent", last_error: "retries exhausted: #{error || "HTTP #{http_status}"}")
    else
      update!(status: "pending",
              next_attempt_at: Time.current + backoff_seconds,
              last_error: error || "HTTP #{http_status}")
    end
  end

  # attempts⁴ + 15 + jitter, Mastodon's curve.
  def backoff_seconds
    (attempts**4) + 15 + rand(0..(attempts * 5))
  end
end
