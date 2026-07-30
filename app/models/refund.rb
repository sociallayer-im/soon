# A refund request against a paid ticket_item. Written as `pending` when the
# organizer initiates it; finalized by the charge.refunded webhook or the
# sweeper, never synchronously (refunds can fail asynchronously at Stripe).
# Full refunds release the seat/coupon/membership; partial refunds move money
# only (design/PAYMENTS_PLAN.md decision #10).
class Refund < ApplicationRecord
  belongs_to :ticket_item
  belongs_to :requested_by, class_name: "User", foreign_key: :requested_by_user_id

  validates :amount, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: %w(pending succeeded failed) }
end
