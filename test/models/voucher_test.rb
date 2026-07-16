require "test_helper"

class VoucherTest < ActiveSupport::TestCase
  def setup
    @sender = create_user
    @badge_class = create_badge_class(creator: @sender)
  end

  # NOTE: Voucher#invalid? is a custom method that shadows ActiveRecord's built-in
  # #invalid? (which normally means "has validation errors"). This is an existing
  # naming collision in the codebase — not something this test suite fixes, just
  # documents. These tests exercise the custom (intended) behavior.

  test "invalid? is true when counter is 0" do
    voucher = create_voucher(sender: @sender, badge_class: @badge_class, counter: 0, expires_at: 90.days.from_now)
    assert voucher.invalid?
  end

  test "invalid? is true when expired" do
    voucher = create_voucher(sender: @sender, badge_class: @badge_class, counter: 5, expires_at: 1.day.ago)
    assert voucher.invalid?
  end

  test "invalid? is false when counter > 0 and expires_at is nil" do
    voucher = create_voucher(sender: @sender, badge_class: @badge_class, counter: 5, expires_at: nil)
    assert_not voucher.invalid?
  end

  test "invalid? is false when counter > 0 and not yet expired" do
    voucher = create_voucher(sender: @sender, badge_class: @badge_class, counter: 5, expires_at: 90.days.from_now)
    assert_not voucher.invalid?
  end

  test "strategy inclusion validation" do
    voucher = Voucher.new(sender: @sender, badge_class: @badge_class, strategy: "bogus", counter: 1)
    assert_not voucher.valid?
    assert_includes voucher.errors[:strategy], "is not included in the list"
  end

  test "counter must be non-negative" do
    voucher = Voucher.new(sender: @sender, badge_class: @badge_class, strategy: "code", counter: -1)
    assert_not voucher.valid?
    assert_includes voucher.errors[:counter], "must be greater than or equal to 0"
  end
end
