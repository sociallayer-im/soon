require "test_helper"

class PaymentMethodTest < ActiveSupport::TestCase
  setup do
    owner = create_user
    group = create_group(owner: owner)
    @event = create_event(group: group, owner: owner)
    @ticket = create_ticket(event: @event)
  end

  # --- currency ---

  test "a card method takes its rail's currency without being asked" do
    pm = create_payment_method(item: @ticket, chain: "stripe", price: 1000)

    assert_equal "usd", pm.currency
  end

  test "a crypto method has no currency — its unit is the token" do
    pm = create_payment_method(item: @ticket, chain: "ethereum", kind: "crypto",
      token_name: "USDT", price: 10_000)

    assert_nil pm.currency
  end

  test "a currency on a crypto method is rejected, not silently kept" do
    pm = PaymentMethod.new(item: @ticket, chain: "ethereum", kind: "crypto",
      token_name: "USDT", price: 10_000, currency: "usd")

    assert_not pm.valid?
    assert_match "does not apply to crypto", pm.errors[:currency].first
  end

  test "a card method cannot be pinned to a currency its rail does not settle" do
    pm = PaymentMethod.new(item: @ticket, chain: "stripe", kind: "fiat", price: 1000,
      currency: "cny", stripe_setting_id: default_stripe_setting_for(@ticket).id)

    assert_not pm.valid?
    assert_match "must be USD", pm.errors[:currency].first
  end

  test "an unknown currency is rejected outright" do
    pm = PaymentMethod.new(item: @ticket, chain: "stripe", kind: "fiat", price: 1000,
      currency: "eur", stripe_setting_id: default_stripe_setting_for(@ticket).id)

    assert_not pm.valid?
    assert pm.errors[:currency].any?
  end

  # A row written before the column was in use has currency NULL. Saving it for
  # any reason should repair that rather than leave an order's currency to be
  # guessed downstream.
  test "saving a legacy card method backfills its currency" do
    pm = create_payment_method(item: @ticket, chain: "stripe", price: 1000)
    pm.update_column(:currency, nil)

    pm.reload.update!(price: 1500)

    assert_equal "usd", pm.reload.currency
  end

  test "a WeChat method takes CNY and the installed platform merchant" do
    merchant = create_wechat_pay_setting
    pm = PaymentMethod.create!(item: @ticket, chain: "wechat", kind: "fiat", price: 100)

    assert_equal "cny", pm.currency
    assert_equal merchant.id, pm.wechat_pay_setting_id
  end

  # The organizer never picks a merchant, so "no merchant installed" can only
  # surface as a validation. Without it the method saves and the failure moves
  # to a buyer standing at checkout.
  test "a WeChat method is refused when no merchant is installed" do
    pm = PaymentMethod.new(item: @ticket, chain: "wechat", kind: "fiat", price: 100)

    assert_not pm.valid?
    assert_match "no WeChat Pay merchant is configured", pm.errors[:wechat_pay_setting_id].first
  end

  test "a WeChat method cannot be priced in USD" do
    create_wechat_pay_setting
    pm = PaymentMethod.new(item: @ticket, chain: "wechat", kind: "fiat", price: 100, currency: "usd")

    assert_not pm.valid?
    assert_match "must be CNY", pm.errors[:currency].first
  end

  # --- price floor ---

  test "the card floor still applies at $4" do
    pm = PaymentMethod.new(item: @ticket, chain: "stripe", kind: "fiat", price: 399,
      stripe_setting_id: default_stripe_setting_for(@ticket).id)

    assert_not pm.valid?
    assert_match "at least $4", pm.errors[:price].first
  end

  # The floor is a per-rail map now. If it ever silently collapses back to one
  # global constant, a rail with no fixed per-charge fee inherits a floor it has
  # no reason for — the mistake design/WECHAT_INTEGRATION.md §2.5 warns about.
  test "the floor is keyed by rail, and crypto has none" do
    assert_equal PaymentMethod::STRIPE_MIN_CENTS, PaymentMethod::MIN_PRICE.fetch("stripe")

    pm = create_payment_method(item: @ticket, chain: "ethereum", kind: "crypto",
      token_name: "USDT", price: 1)

    assert pm.valid?
  end

  # ¥0.01. Legitimate on a rail with no fixed per-charge fee, and the exact
  # case a copied 400 would have banned.
  test "WeChat accepts a one-fen ticket" do
    create_wechat_pay_setting
    pm = PaymentMethod.new(item: @ticket, chain: "wechat", kind: "fiat", price: 1)

    assert pm.valid?, pm.errors.full_messages.join(", ")
  end

  test "a free WeChat price is still refused — zero is the free path, not a price" do
    create_wechat_pay_setting
    pm = PaymentMethod.new(item: @ticket, chain: "wechat", kind: "fiat", price: 0)

    assert_not pm.valid?
  end

  test "fiat_chain names the rail, and is nil for crypto" do
    card = create_payment_method(item: @ticket, chain: "stripe", price: 1000)
    crypto = create_payment_method(item: @ticket, chain: "ethereum", kind: "crypto",
      token_name: "USDT", price: 10_000)

    assert_equal "stripe", card.fiat_chain
    assert card.fiat?
    assert_nil crypto.fiat_chain
    assert_not crypto.fiat?
  end

  # Multi-chain methods carry their chains in `chains`, leaving `chain` blank —
  # fiat detection has to look at the resolved set or it reads every such
  # method as crypto (and vice versa).
  test "fiat detection reads the chains array, not just chain" do
    pm = create_payment_method(item: @ticket, chain: nil, kind: "crypto",
      chains: %w[ethereum base], token_name: "USDT", price: 10_000)

    assert_nil pm.fiat_chain
    assert_nil pm.currency
  end
end
