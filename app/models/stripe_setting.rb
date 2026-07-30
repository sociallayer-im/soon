# One Stripe API key belonging to a user. A user may hold several (live and
# test, or separate accounts for different events); which key a ticket
# charges to is picked at ticket-creation time and stored on the
# payment_method. Orders snapshot the setting id so refunds/verification
# always use the account that took the money (design/PAYMENTS_PLAN.md §2.1).
class StripeSetting < ApplicationRecord
  belongs_to :user
  has_many :payment_methods, dependent: nil

  # Stored in plaintext by decision (2026-07-30) — no Active Record
  # encryption. The protections that remain: keys never leave the server
  # unmasked (blueprint renders masked_key only), and filter_parameter_logging
  # keeps them out of logs.

  validates :name, presence: true
  validates :secret_key, presence: true
  # pk_ keys are publishable (browser-side) and cannot call the API at all —
  # Stripe answers 401, which reads as "rejected" with no hint why. This is
  # the single easiest mistake to make here, so name it explicitly.
  validate :secret_key_is_not_publishable
  validates :mode, inclusion: { in: %w(live test) }
  validates :status, inclusion: { in: %w(active invalid) }
  validates :currency, presence: true

  before_validation :detect_mode

  def test_mode? = mode == "test"

  # The only key-derived value that may ever reach a serializer or the UI.
  def masked_key = "…#{secret_key.to_s.last(4)}"

  private

  # sk_test_/rk_test_ prefixes mark Stripe test keys; everything else is live.
  def detect_mode
    self.mode = secret_key.to_s.match?(/\A[a-z]+_test_/) ? "test" : "live" if secret_key.present?
  end

  def secret_key_is_not_publishable
    return if secret_key.blank?
    return unless secret_key.to_s.start_with?("pk_")

    errors.add(:secret_key,
      "is a publishable key (pk_…), which cannot charge cards. Use the Secret key (sk_…) " \
      "or a Restricted key (rk_…) from Stripe Dashboard → Developers → API keys")
  end
end
