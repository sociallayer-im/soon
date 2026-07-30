# One received Stripe webhook delivery. The primary key is Stripe's own
# event id (evt_…), so a duplicate delivery fails the insert — that unique
# violation IS the idempotency check (design/PAYMENTS_PLAN.md §2.3).
# processed_at/error record what the async handler did with it.
class StripeEvent < ApplicationRecord
  belongs_to :stripe_setting

  validates :event_type, presence: true

  scope :unprocessed, -> { where(processed_at: nil) }
end
