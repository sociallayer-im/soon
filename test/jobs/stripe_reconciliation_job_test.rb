require "test_helper"
require "ostruct"

class StripeReconciliationJobTest < ActiveSupport::TestCase
  include FactoryHelpers

  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @ticket = create_ticket(event: @event, quantity: 5)
    @setting = StripeSetting.create!(user: @owner, name: "K", secret_key: "sk_live_k")
    @buyer = create_user
  end

  def create_paid_order(**attrs)
    TicketItem.create!({ ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: "succeeded", amount: 1000, currency: "usd", payment_provider: "stripe",
      stripe_setting_id: @setting.id, paid_at: 1.day.ago, txhash: "pi_#{SecureRandom.hex(4)}" }.merge(attrs))
  end

  def intent_with(charge_attrs)
    OpenStruct.new(latest_charge: OpenStruct.new({ dispute: nil, amount_refunded: 0 }.merge(charge_attrs)))
  end

  test "an order fully refunded at Stripe (webhook missed) is finalized with side effects" do
    item = create_paid_order

    StripeGateway.stub :retrieve_payment_intent, intent_with(amount_refunded: 1000) do
      StripeReconciliationJob.perform_now
    end

    assert_equal "refunded", item.reload.status
    assert_equal 6, @ticket.reload.quantity
    refund = item.refunds.sole
    assert_equal "succeeded", refund.status
    assert refund.full_refund
    assert_equal "found by reconciliation", refund.reason
  end

  test "a partial dashboard refund marks partially_refunded without releasing the seat" do
    item = create_paid_order

    StripeGateway.stub :retrieve_payment_intent, intent_with(amount_refunded: 300) do
      StripeReconciliationJob.perform_now
    end

    assert_equal "partially_refunded", item.reload.status
    assert_equal 5, @ticket.reload.quantity
    assert_not item.refunds.sole.full_refund
  end

  test "a dispute at Stripe marks the order disputed" do
    item = create_paid_order

    StripeGateway.stub :retrieve_payment_intent, intent_with(dispute: "dp_1") do
      StripeReconciliationJob.perform_now
    end
    assert_equal "disputed", item.reload.status
  end

  test "a clean order is left alone" do
    clean = create_paid_order
    StripeGateway.stub :retrieve_payment_intent, intent_with({}) do
      StripeReconciliationJob.perform_now
    end
    assert_equal "succeeded", clean.reload.status
    assert_equal 5, @ticket.reload.quantity
  end

  test "a second run after fixing is a no-op (released exactly once)" do
    refunded = create_paid_order
    StripeGateway.stub :retrieve_payment_intent, intent_with(amount_refunded: 1000) do
      StripeReconciliationJob.perform_now
      StripeReconciliationJob.perform_now # idempotent
    end
    assert_equal "refunded", refunded.reload.status
    assert_equal 6, @ticket.reload.quantity, "released exactly once across runs"
    assert_equal 1, refunded.refunds.count
  end

  test "an unreachable key or intent is skipped, not crashed on" do
    create_paid_order
    StripeGateway.stub :retrieve_payment_intent, nil do
      assert_nothing_raised { StripeReconciliationJob.perform_now }
    end
  end
end
