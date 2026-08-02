# One row = one signed POST owed to one inbox. Written in the same
# transaction as the business change (outbox pattern), drained by the
# sweeper under a rate cap — never delivered inline
# (design/FEDERATION_PLAN.md §2.6, design/FEDERATION_TEST_PLAN.md §2).
class FedDelivery < ApplicationRecord
  STATUSES = %w[pending delivering delivered failed_permanent suppressed].freeze
  MAX_ATTEMPTS = 10
  # Mastodon semantics: these response codes are retryable, every other 4xx
  # (and 501) is permanent.
  RETRYABLE_HTTP = [401, 408, 429].freeze

  # the private half of the snapshotted signing identity (P1-1)
  encrypts :signing_key_pem

  validates :status, inclusion: {in: STATUSES}
  validates :inbox_url, presence: true
  validates :payload, presence: true

  scope :due, -> {
    where(status: "pending").where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
  }

  def self.retryable_status?(http_status)
    return true if http_status.nil? # transport error, no response
    return false if http_status == 501
    # 3xx on a signed POST is a misconfigured inbox — HttpClient refuses to
    # follow it (replaying a signed request at a new host), and retrying the
    # same URL would loop forever.
    return false if (300..399).cover?(http_status)
    return true if RETRYABLE_HTTP.include?(http_status)
    !(400..499).cover?(http_status)
  end

  def mark_result!(http_status, error: nil, retry_after: nil)
    if http_status && (200..299).cover?(http_status)
      update!(status: "delivered", last_error: nil)
    elsif !self.class.retryable_status?(http_status)
      update!(status: "failed_permanent", last_error: error || "HTTP #{http_status}")
    elsif attempts >= MAX_ATTEMPTS
      update!(status: "failed_permanent", last_error: "retries exhausted: #{error || "HTTP #{http_status}"}")
    else
      # honour Retry-After (429/503): never retry earlier than the remote
      # asked, while keeping at least our own backoff
      wait = [backoff_seconds, self.class.parse_retry_after(retry_after) || 0].max
      update!(status: "pending",
              next_attempt_at: Time.current + wait,
              last_error: error || "HTTP #{http_status}")
    end
  end

  # Retry-After arrives as delta-seconds or an HTTP-date. Bounded to a day so
  # a hostile header can't park a delivery for a year.
  def self.parse_retry_after(value)
    return nil if value.blank?
    seconds =
      if value.to_s.match?(/\A\d+\z/)
        value.to_i
      else
        begin
          (Time.httpdate(value.to_s) - Time.current).to_i
        rescue ArgumentError
          nil
        end
      end
    seconds && seconds.clamp(0, 86_400)
  end

  # attempts⁴ + 15 + jitter, Mastodon's curve.
  def backoff_seconds
    (attempts**4) + 15 + rand(0..(attempts * 5))
  end
end
