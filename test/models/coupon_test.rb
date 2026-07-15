require "test_helper"

class CouponTest < ActiveSupport::TestCase
  def setup
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
  end

  test "ratio discount is basis points of 10000, not a 0-100 percentage" do
    coupon = create_coupon(event: @event, discount_type: "ratio", discount: 2000, max_allowed_usages: 10)
    # amount * discount / 10_000 = 1000 * 2000 / 10_000 = 200
    amount, discount_value, discount_data = coupon.get_discounted_price(1000, nil)
    assert_equal 200, amount
    assert_equal 800, discount_value
    assert_equal "id=#{coupon.id}|ratio|800", discount_data
  end

  test "invalid ratio (>10000 or <0) applies no discount" do
    coupon = create_coupon(event: @event, discount_type: "ratio", discount: 15_000, max_allowed_usages: 10)
    amount, discount_value, discount_data = coupon.get_discounted_price(1000, nil)
    assert_equal 1000, amount
    assert_nil discount_value
    assert_nil discount_data
  end

  test "amount discount is used as-is for a stripe payment method" do
    ticket = create_ticket(event: @event)
    stripe_pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    coupon = create_coupon(event: @event, discount_type: "amount", discount: 300, max_allowed_usages: 10)

    amount, discount_value, = coupon.get_discounted_price(1000, stripe_pm)
    assert_equal 700, amount
    assert_equal 300, discount_value
  end

  test "amount discount is scaled x10000 for a non-stripe (crypto) payment method" do
    ticket = create_ticket(event: @event)
    crypto_pm = create_payment_method(item: ticket, chain: "base", price: 1_000_000)
    coupon = create_coupon(event: @event, discount_type: "amount", discount: 30, max_allowed_usages: 10)

    # discount_value = 30 * 10_000 = 300_000
    amount, discount_value, = coupon.get_discounted_price(1_000_000, crypto_pm)
    assert_equal 700_000, amount
    assert_equal 300_000, discount_value
  end

  test "amount discount with paymethod nil is used as-is" do
    coupon = create_coupon(event: @event, discount_type: "amount", discount: 300, max_allowed_usages: 10)
    amount, discount_value, = coupon.get_discounted_price(1000, nil)
    assert_equal 700, amount
    assert_equal 300, discount_value
  end

  test "amount discount is clamped to never exceed the item's price" do
    coupon = create_coupon(event: @event, discount_type: "amount", discount: 5000, max_allowed_usages: 10)
    amount, discount_value, = coupon.get_discounted_price(1000, nil)
    assert_equal 0, amount
    assert_equal 1000, discount_value
  end

  test "expired coupon applies no discount and raises no error" do
    coupon = create_coupon(event: @event, discount_type: "ratio", discount: 5000, expires_at: 1.day.ago, max_allowed_usages: 10)
    amount, discount_value, discount_data = coupon.get_discounted_price(1000, nil)
    assert_equal 1000, amount
    assert_nil discount_value
    assert_nil discount_data
  end

  test "usage-exhausted coupon applies no discount" do
    coupon = create_coupon(event: @event, discount_type: "ratio", discount: 5000, max_allowed_usages: 1, order_usage_count: 1)
    amount, discount_value, = coupon.get_discounted_price(1000, nil)
    assert_equal 1000, amount
    assert_nil discount_value
  end

  test "before_save auto-generates a code and expiry when blank" do
    coupon = Coupon.new(event: @event, selector_type: "code", discount_type: "ratio", discount: 100, max_allowed_usages: 10)
    coupon.save!
    assert coupon.code.present?
    assert coupon.expires_at.present?
    assert_in_delta 30.days.from_now.to_i, coupon.expires_at.to_i, 5
  end

  test "before_save preserves an explicitly given code and expiry" do
    explicit_expiry = 10.days.from_now
    coupon = Coupon.create!(event: @event, selector_type: "code", code: "MYCODE", discount_type: "ratio",
      discount: 100, max_allowed_usages: 10, expires_at: explicit_expiry)
    assert_equal "MYCODE", coupon.code
    assert_in_delta explicit_expiry.to_i, coupon.expires_at.to_i, 2
  end

  test "selector_type and discount_type inclusion validations" do
    coupon = Coupon.new(event: @event, selector_type: "invalid", discount_type: "invalid", discount: 100, max_allowed_usages: 10)
    assert_not coupon.valid?
    assert_includes coupon.errors[:selector_type], "is not included in the list"
    assert_includes coupon.errors[:discount_type], "is not included in the list"
  end
end
