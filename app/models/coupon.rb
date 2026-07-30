class Coupon < ApplicationRecord
  belongs_to :event

  validates :selector_type, inclusion: { in: %w(code email badge) }
  validates :discount_type, inclusion: { in: %w(ratio amount) }

  before_save :assign_defaults

  # Single source of truth for redeemability. max_allowed_usages is nullable
  # (nil == unlimited); guarding it here prevents `nil <= count` NoMethodErrors.
  def available?
    return false if removed
    return false if expires_at && expires_at < Time.current
    return false if max_allowed_usages && order_usage_count >= max_allowed_usages
    true
  end

  # Applies to every ticket of the event when the list is empty.
  def applicable_to?(ticket)
    applicable_ticket_ids.blank? || applicable_ticket_ids.include?(ticket.id)
  end

  # Discount math, preserved exactly from sails/:
  # - ratio discount is basis points of 10000 (discount: 500 == 5%), not 0-100
  # - amount discount is scaled x10000 for non-stripe chains vs used as-is for stripe
  #
  # `chain` is the chain actually selected for this order (for multi-chain payment
  # methods paymethod.chain is blank, so the amount-scaling must key off the
  # resolved chain, not paymethod.chain).
  def get_discounted_price(amount, paymethod, chain: nil)
    amount = amount.to_i
    original_amount = amount
    chain ||= paymethod&.chain

    return [amount, nil, nil] unless available?

    if discount_type == "ratio"
      return [amount, nil, nil] if discount > 10_000 || discount < 0
      amount = amount * discount / 10_000
    elsif discount_type == "amount"
      # stripe amounts are already in the smallest unit (cents); crypto amounts
      # are scaled x10000. Unknown chain (no payment context) → use as-is.
      discount_value = (chain == "stripe" || chain.nil?) ? discount : discount * 10_000
      discount_value = amount if discount_value > amount
      amount -= discount_value
    end

    discount_value = original_amount - amount
    discount_data = "id=#{id}|#{discount_type}|#{discount_value}"
    [amount, discount_value, discount_data]
  end

  private

  def assign_defaults
    self.code = SecureRandom.hex(6) if code.blank?
    self.expires_at = 30.days.from_now if expires_at.blank?
  end
end
