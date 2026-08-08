require "test_helper"

class Ticketing::ActivityTest < ActiveSupport::TestCase
  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @ticket = create_ticket(event: @event, quantity: 5)
    @buyer = create_user
  end

  def create_order(**attrs)
    TicketItem.create!({ ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: "pending", amount: 1000, currency: "usd", payment_provider: "stripe" }.merge(attrs))
  end

  test "every transition writes a row, and it names what caused it" do
    item = create_order

    assert_difference "Ticketing::Activity.count", 1 do
      item.confirm_payment!(txhash: "pi_1", source: "webhook")
    end

    row = item.ticketing_activities.sole
    assert_equal "payment_confirmed", row.action
    assert_equal "pending", row.from_status
    assert_equal "succeeded", row.to_status
    assert_equal "webhook", row.source
    assert_equal "stripe", row.metadata["provider"]
  end

  # The distinction the whole table exists for. Both land on `refunded` with
  # identical columns; only the action separates "we refunded them" from "the
  # bank took it back".
  test "a lost dispute is distinguishable from a voluntary refund" do
    lost = create_order(status: "succeeded")
    lost.transition!(:disputed, source: "webhook")
    lost.transition!(:refunded, source: "webhook", reason: "dispute lost")

    voluntary = create_order(status: "succeeded")
    refund = voluntary.refunds.create!(requested_by: @owner, amount: 1000, currency: "usd", full_refund: true)
    voluntary.apply_refund_success!(refund)

    assert_equal %w[dispute_opened dispute_lost], lost.ticketing_activities.oldest_first.map(&:action)
    assert_includes voluntary.ticketing_activities.map(&:action), "refund_succeeded"
    assert_equal "refunded", lost.reload.status
    assert_equal "refunded", voluntary.reload.status
  end

  test "a dispute won is recorded as won, not as a fresh payment" do
    item = create_order(status: "succeeded")
    item.transition!(:disputed, source: "webhook")
    item.transition!(:succeeded, source: "webhook")

    assert_equal "dispute_won", item.ticketing_activities.oldest_first.last.action
  end

  # Non-transition events are the ones a status column can never explain.
  test "events that change no status are still recorded" do
    item = create_order

    item.record_activity!("payment_retried", source: "api", actor: @buyer, prepay_id: "pp_2")
    item.record_activity!("callback_rejected", source: "webhook", reason: "amount mismatch")

    assert_equal %w[payment_retried callback_rejected], item.ticketing_activities.oldest_first.map(&:action)
    assert_equal "pending", item.reload.status, "neither may move the order"
    assert_nil item.ticketing_activities.first.to_status
  end

  test "rows are append-only — an observation is never edited" do
    item = create_order
    item.record_activity!("payment_retried", source: "api")
    row = item.ticketing_activities.sole

    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(reason: "rewritten") }
  end

  # An audit row failing must never take a payment down with it: a lost row is
  # bad, a lost confirmation is worse.
  test "a failure to record does not break the transition" do
    item = create_order

    Ticketing::Activity.stub :create!, ->(*) { raise ActiveRecord::StatementInvalid, "table gone" } do
      item.confirm_payment!(txhash: "pi_2")
    end

    assert_equal "succeeded", item.reload.status
  end

  test "an order's history outlives a deleted refund" do
    item = create_order(status: "succeeded")
    refund = item.refunds.create!(requested_by: @owner, amount: 500, currency: "usd", full_refund: false)
    item.apply_refund_success!(refund)
    refund.destroy!

    assert_includes item.ticketing_activities.map(&:action), "refund_succeeded"
  end

  test "backfilled rows are marked and excluded from recorded" do
    item = create_order
    Ticketing::Activity.record!(item, "order_placed", source: "backfill")
    Ticketing::Activity.record!(item, "payment_retried", source: "api")

    assert_equal 2, item.ticketing_activities.count
    assert_equal %w[payment_retried], Ticketing::Activity.recorded.where(subject: item).map(&:action)
    assert Ticketing::Activity.find_by(subject: item, action: "order_placed").backfilled?
  end

  test "an unknown action or source is refused" do
    item = create_order

    assert_not Ticketing::Activity.new(subject: item, action: "whatever", source: "api").valid?
    assert_not Ticketing::Activity.new(subject: item, action: "order_placed", source: "somewhere").valid?
  end
end
