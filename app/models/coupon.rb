class Coupon < ApplicationRecord
  belongs_to :event

  validates :selector_type, inclusion: { in: %w(code email badge) }
  validates :discount_type, inclusion: { in: %w(ratio amount) }

  before_save :assign_defaults

  # Discount math, preserved exactly from sails/:
  # - ratio discount is basis points of 10000 (discount: 500 == 5%), not 0-100
  # - amount discount is scaled x10000 for non-stripe chains vs used as-is for stripe
  def get_discounted_price(amount, paymethod)
    amount = amount.to_i
    original_amount = amount

    if expires_at < Time.current || max_allowed_usages <= order_usage_count
      return [amount, nil, nil]
    end

    if discount_type == "ratio"
      return [amount, nil, nil] if discount > 10_000 || discount < 0
      amount = amount * discount / 10_000
    elsif discount_type == "amount"
      discount_value =
        if paymethod
          paymethod.chain == "stripe" ? discount : discount * 10_000
        else
          discount
        end
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
