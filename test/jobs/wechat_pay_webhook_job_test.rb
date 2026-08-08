require "test_helper"

class WechatPayWebhookJobTest < ActiveSupport::TestCase
  include FactoryHelpers

  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @ticket = create_ticket(event: @event, quantity: 5)
    @merchant = create_wechat_pay_setting
    @buyer = create_user
  end

  def create_order(status: "pending", **attrs)
    TicketItem.create!({ ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: status, amount: 100, currency: "cny", payment_provider: "wechat",
      wechat_pay_setting_id: @merchant.id }.merge(attrs))
  end

  def deliver(event_type, resource, setting: @merchant)
    record = WechatPayEvent.create!(
      id: "EV-#{SecureRandom.hex(6)}", wechat_pay_setting_id: setting.id,
      event_type: event_type, payload: { "id" => "x", "event_type" => event_type, "resource" => resource }
    )
    WechatPayWebhookJob.perform_now(record.id)
    record.reload
  end

  def transaction(item, **overrides)
    {
      "out_trade_no" => item.id, "transaction_id" => "4200001", "trade_state" => "SUCCESS",
      "mchid" => @merchant.mchid, "appid" => @merchant.app_id,
      "amount" => { "total" => item.amount, "currency" => "CNY", "payer_total" => item.amount },
      "payer" => { "openid" => "o_buyer" }
    }.merge(overrides.transform_keys(&:to_s))
  end

  test "TRANSACTION.SUCCESS confirms the order and records the transaction id" do
    item = create_order

    record = deliver("TRANSACTION.SUCCESS", transaction(item))

    assert_equal "succeeded", item.reload.status
    assert_equal "4200001", item.txhash
    assert_nil record.error
    assert_not_nil record.processed_at
  end

  # A notification can arrive for a state that is not SUCCESS; the event type
  # alone is not the verdict.
  test "a non-SUCCESS trade_state confirms nothing" do
    item = create_order

    record = deliver("TRANSACTION.SUCCESS", transaction(item, trade_state: "CLOSED"))

    assert_equal "pending", item.reload.status
    assert_match "trade_state CLOSED", record.error
  end

  test "an underpaid notification is refused rather than confirmed" do
    item = create_order

    record = deliver("TRANSACTION.SUCCESS", transaction(item, amount: { "total" => 1, "currency" => "CNY" }))

    assert_equal "pending", item.reload.status
    assert_match "amount/currency mismatch", record.error
  end

  # A validly signed callback from merchant A must not settle an order whose
  # money sits with merchant B.
  test "a callback from a different merchant cannot touch the order" do
    item = create_order
    other = create_wechat_pay_setting

    record = deliver("TRANSACTION.SUCCESS", transaction(item), setting: other)

    assert_equal "pending", item.reload.status
    assert_match "merchant mismatch", record.error
  end

  test "a redelivered success is a no-op, not a second confirmation" do
    item = create_order
    deliver("TRANSACTION.SUCCESS", transaction(item))
    count_before = @ticket.reload.quantity

    record = deliver("TRANSACTION.SUCCESS", transaction(item))

    assert_equal "succeeded", item.reload.status
    assert_nil record.error
    assert_equal count_before, @ticket.reload.quantity
  end

  # Two different WeChat transactions settling one order means money was taken
  # twice for one seat — worth surfacing, never worth applying.
  test "a second DIFFERENT transaction on a settled order is flagged" do
    item = create_order(status: "succeeded", txhash: "4200000_first")

    record = deliver("TRANSACTION.SUCCESS", transaction(item, transaction_id: "4200002_second"))

    assert_match "duplicate payment", record.error
  end

  test "REFUND.SUCCESS finalizes our pending refund and releases the seat" do
    item = create_order(status: "succeeded", txhash: "4200001", participant: nil)
    refund = item.refunds.create!(requested_by: @owner, amount: 100, currency: "cny", full_refund: true)

    deliver("REFUND.SUCCESS", {
      "out_trade_no" => item.id, "out_refund_no" => refund.id, "refund_id" => "50000_r",
      "refund_status" => "SUCCESS", "amount" => { "total" => 100, "refund" => 100 }
    })

    assert_equal "succeeded", refund.reload.status
    assert_equal "50000_r", refund.provider_ref
    assert_equal "refunded", item.reload.status
    assert_equal 6, @ticket.reload.quantity
  end

  # Refunded from 商户平台 rather than through our API: the seat, coupon and
  # membership still have to come back.
  test "a refund with no local row is recorded and still applies its side effects" do
    item = create_order(status: "succeeded", txhash: "4200001")

    deliver("REFUND.SUCCESS", {
      "out_trade_no" => item.id, "out_refund_no" => "console_1", "refund_id" => "50000_c",
      "refund_status" => "SUCCESS", "amount" => { "total" => 100, "refund" => 100 }
    })

    assert_equal "refunded", item.reload.status
    assert_equal 1, item.refunds.count
    assert_match "merchant console", item.refunds.first.reason
  end

  # The money did NOT move, so the seat must not be released — only the
  # pending row is cleared, which also frees the one-live-full-refund index
  # so the organizer can try again.
  test "REFUND.ABNORMAL fails the refund without releasing anything" do
    item = create_order(status: "succeeded", txhash: "4200001")
    refund = item.refunds.create!(requested_by: @owner, amount: 100, currency: "cny", full_refund: true)

    deliver("REFUND.ABNORMAL", {
      "out_trade_no" => item.id, "out_refund_no" => refund.id, "refund_status" => "ABNORMAL"
    })

    assert_equal "failed", refund.reload.status
    assert_equal "succeeded", item.reload.status
    assert_equal 5, @ticket.reload.quantity

    # And a retry is now possible.
    assert item.refunds.create(requested_by: @owner, amount: 100, currency: "cny", full_refund: true).persisted?
  end

  test "a callback for an unknown order is recorded, not raised" do
    record = deliver("TRANSACTION.SUCCESS", { "out_trade_no" => "nosuchorder", "trade_state" => "SUCCESS" })

    assert_match "no wechat order", record.error
    assert_not_nil record.processed_at
  end
end
