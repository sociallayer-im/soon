require "test_helper"
require "ostruct"

class TicketingSweeperJobTest < ActiveSupport::TestCase
  include FactoryHelpers

  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @ticket = create_ticket(event: @event, quantity: 5)
    @setting = StripeSetting.create!(user: @owner, name: "K", secret_key: "sk_live_k")
    @buyer = create_user
  end

  def create_stale_order(**attrs)
    TicketItem.create!({ ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: "pending", amount: 1000, currency: "usd", payment_provider: "stripe",
      stripe_setting_id: @setting.id, provider_ref: "cs_#{SecureRandom.hex(4)}",
      reserved_until: 5.minutes.ago }.merge(attrs))
  end

  test "event cancellation expires an open Stripe session before finalizing" do
    order = create_stale_order(reserved_until: 20.minutes.from_now)
    assert_not @event.cancel_by!(@owner)
    assert_equal "cancelling", @event.reload.status
    open_session = OpenStruct.new(status: "open", payment_status: "unpaid")
    expired_session = OpenStruct.new(status: "expired", payment_status: "unpaid")

    StripeGateway.stub :retrieve_checkout_session, open_session do
      StripeGateway.stub :expire_checkout_session, expired_session do
        TicketingSweeperJob.perform_now(event_id: @event.id)
      end
    end

    assert_equal "cancelled", order.reload.status
    assert_equal "cancelled", @event.reload.status
    assert Activity.exists?(item: @event, initiator: @owner, action: "event/cancellation_recorded")
  end

  test "a late Stripe payment is recorded once and does not reopen the event" do
    order = create_stale_order
    order.timeout
    assert @event.cancel_by!(@owner)

    2.times { order.confirm_payment!(txhash: "pi_late", source: "webhook") }
    assert_equal "cancelled", @event.reload.status
    assert_equal "succeeded", order.reload.status
    assert_equal "pi_late", order.txhash
    assert_equal 1, Activity.where(item: @event, action: "event/late_payment_requires_refund").count
    assert_nil order.participant_id
  end

  test "a payment racing Stripe expiration waits for its refund" do
    order = create_stale_order
    assert_not @event.cancel_by!(@owner)
    open_session = OpenStruct.new(status: "open", payment_status: "unpaid")
    paid_session = OpenStruct.new(status: "complete", payment_status: "paid", payment_intent: "pi_race")
    responses = [open_session, paid_session]

    StripeGateway.stub :retrieve_checkout_session, ->(*) { responses.shift } do
      StripeGateway.stub :expire_checkout_session, nil do
        TicketingSweeperJob.perform_now(event_id: @event.id)
      end
    end

    assert_equal "succeeded", order.reload.status
    assert_equal "cancelling", @event.reload.status
    refund = order.refunds.create!(requested_by: @owner, amount: 1000, currency: "usd", full_refund: true)
    order.apply_refund_success!(refund)
    TicketingSweeperJob.perform_now(event_id: @event.id)
    assert_equal "cancelled", @event.reload.status
  end

  test "a stale order whose session Stripe reports paid is confirmed, not expired" do
    item = create_stale_order
    session = OpenStruct.new(payment_status: "paid", status: "complete", payment_intent: "pi_swept")

    StripeGateway.stub :retrieve_checkout_session, session do
      TicketingSweeperJob.perform_now
    end
    assert_equal "succeeded", item.reload.status
    assert_equal "pi_swept", item.txhash
  end

  test "a still-open session gets another interval instead of being expired under the buyer" do
    item = create_stale_order
    session = OpenStruct.new(payment_status: "unpaid", status: "open")

    StripeGateway.stub :retrieve_checkout_session, session do
      TicketingSweeperJob.perform_now
    end
    assert_equal "pending", item.reload.status
    assert item.reserved_until > Time.current
  end

  test "an expired session times the order out and releases inventory" do
    item = create_stale_order
    session = OpenStruct.new(payment_status: "unpaid", status: "expired")

    StripeGateway.stub :retrieve_checkout_session, session do
      TicketingSweeperJob.perform_now
    end
    assert_equal "timeout", item.reload.status
    assert_equal 6, @ticket.reload.quantity
  end

  test "an unreachable Stripe (nil session) is skipped — never expired on a guess" do
    item = create_stale_order
    StripeGateway.stub :retrieve_checkout_session, nil do
      TicketingSweeperJob.perform_now
    end
    assert_equal "pending", item.reload.status, "cannot-ask-Stripe must not be treated as not-paid"
    assert_equal 5, @ticket.reload.quantity
  end

  test "a stale crypto order times out without any Stripe involvement" do
    item = TicketItem.create!(ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: "pending", amount: 1000, payment_provider: "evm", chain: "base",
      reserved_until: 5.minutes.ago)
    TicketingSweeperJob.perform_now
    assert_equal "timeout", item.reload.status
    assert_equal 6, @ticket.reload.quantity
  end

  # ---------------------------------------------------------------- wechat

  def create_stale_wechat_order(**attrs)
    @merchant ||= create_wechat_pay_setting
    TicketItem.create!({ ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: "pending", amount: 100, currency: "cny", payment_provider: "wechat",
      wechat_pay_setting_id: @merchant.id, reserved_until: 5.minutes.ago }.merge(attrs))
  end

  test "a failed WeChat close keeps cancellation processing until the payment is known" do
    item = create_stale_wechat_order
    assert_not @event.cancel_by!(@owner)

    WechatPayGateway.stub :query_order, { "trade_state" => "NOTPAY" } do
      WechatPayGateway.stub :close_order, false do
        TicketingSweeperJob.perform_now(event_id: @event.id)
      end
    end
    assert_equal "pending", item.reload.status
    assert_equal "cancelling", @event.reload.status

    WechatPayGateway.stub :query_order, { "trade_state" => "CLOSED" } do
      TicketingSweeperJob.perform_now(event_id: @event.id)
    end
    assert_equal "cancelled", item.reload.status
    assert_equal "cancelled", @event.reload.status
  end

  test "a stale wechat order WeChat reports paid is confirmed, not expired" do
    item = create_stale_wechat_order

    WechatPayGateway.stub :query_order, { "trade_state" => "SUCCESS", "transaction_id" => "42000_swept" } do
      TicketingSweeperJob.perform_now
    end
    assert_equal "succeeded", item.reload.status
    assert_equal "42000_swept", item.txhash
  end

  # The step Stripe does not need. A WeChat order stays payable forever unless
  # closed, so releasing the seat without closing is how you end up holding
  # money for a ticket that no longer exists.
  test "an unpaid wechat order is CLOSED before it is expired" do
    item = create_stale_wechat_order
    closed = []

    WechatPayGateway.stub :query_order, { "trade_state" => "NOTPAY" } do
      WechatPayGateway.stub :close_order, ->(_setting, out_trade_no) { closed << out_trade_no; true } do
        TicketingSweeperJob.perform_now
      end
    end
    assert_equal [ item.id ], closed, "the order must be closed, or it stays payable after the seat is released"
    assert_equal "timeout", item.reload.status
    assert_equal 6, @ticket.reload.quantity
  end

  test "a buyer mid-payment (USERPAYING) gets another interval, not an expiry" do
    item = create_stale_wechat_order

    WechatPayGateway.stub :query_order, { "trade_state" => "USERPAYING" } do
      TicketingSweeperJob.perform_now
    end
    assert_equal "pending", item.reload.status
    assert item.reserved_until > Time.current
  end

  test "an unreachable WeChat (nil) is skipped and nothing is closed" do
    item = create_stale_wechat_order
    closed = false

    WechatPayGateway.stub :query_order, nil do
      WechatPayGateway.stub :close_order, ->(*) { closed = true } do
        TicketingSweeperJob.perform_now
      end
    end
    assert_equal "pending", item.reload.status, "cannot-ask must not be treated as not-paid"
    assert_not closed
    assert_equal 5, @ticket.reload.quantity
  end

  test "orders with no reserved_until (legacy) are left alone" do
    item = TicketItem.create!(ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: "pending", amount: 1000, payment_provider: "evm", chain: "base")
    TicketingSweeperJob.perform_now
    assert_equal "pending", item.reload.status
  end
end
