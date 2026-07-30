# One Stripe API key belonging to a user. A user may hold several (live and
# test, or separate accounts for different events); which key a ticket
# charges to is picked at ticket-creation time and stored on the
# payment_method. Orders snapshot the setting id so refunds/verification
# always use the account that took the money (design/PAYMENTS_PLAN.md §2.1).
class StripeSetting < ApplicationRecord
  belongs_to :user
  has_many :payment_methods, dependent: nil

  encrypts :secret_key
  encrypts :webhook_secret

  validates :name, presence: true
  validates :secret_key, presence: true
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
end
