require "test_helper"

class StripeWebhookJobTest < ActiveSupport::TestCase
  include FactoryHelpers

  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @ticket = create_ticket(event: @event, quantity: 5)
    @setting = StripeSetting.create!(user: @owner, name: "K", secret_key: "sk_live_k", webhook_secret: "whsec_x")
    @buyer = create_user
  end

  def create_order(status: "pending", **attrs)
    TicketItem.create!({ ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: status, amount: 1000, currency: "usd", payment_provider: "stripe",
      stripe_setting_id: @setting.id }.merge(attrs))
  end

  def record_event(type, object)
    StripeEvent.create!(id: "evt_#{SecureRandom.hex(6)}", stripe_setting_id: @setting.id,
      event_type: type, payload: { "data" => { "object" => object } })
  end

  test "checkout.session.completed confirms a pending order and stamps the intent" do
    item = create_order(provider_ref: "cs_1")
    ev = record_event("checkout.session.completed",
      { "id" => "cs_1", "payment_status" => "paid", "amount_total" => 1000, "currency" => "usd",
        "payment_intent" => "pi_1", "metadata" => { "ticket_item_id" => item.id } })

    StripeWebhookJob.perform_now(ev.id)

    assert_equal "succeeded", item.reload.status
    assert_equal "pi_1", item.txhash
    assert item.paid_at.present?
    assert ev.reload.processed_at.present?
    assert_nil ev.error
  end

  test "completed session resolves by metadata even when the provider_ref write was lost" do
    item = create_order(provider_ref: nil)
    ev = record_event("checkout.session.completed",
      { "id" => "cs_lost", "payment_status" => "paid", "amount_total" => 1000, "currency" => "usd",
        "payment_intent" => "pi_2", "metadata" => { "ticket_item_id" => item.id } })

    StripeWebhookJob.perform_now(ev.id)
    assert_equal "succeeded", item.reload.status
  end

  test "an amount-total below the order amount does not confirm (mismatch recorded)" do
    item = create_order(provider_ref: "cs_cheap")
    ev = record_event("checkout.session.completed",
      { "id" => "cs_cheap", "payment_status" => "paid", "amount_total" => 500, "currency" => "usd",
        "payment_intent" => "pi_3", "metadata" => { "ticket_item_id" => item.id } })

    StripeWebhookJob.perform_now(ev.id)
    assert_equal "pending", item.reload.status
    assert_match "mismatch", ev.reload.error
  end

  test "a late success after cancellation is recorded as an error, never resurrects the order" do
    item = create_order(provider_ref: "cs_late")
    item.cancel
    quantity_after_release = @ticket.reload.quantity

    ev = record_event("checkout.session.completed",
      { "id" => "cs_late", "payment_status" => "paid", "amount_total" => 1000, "currency" => "usd",
        "payment_intent" => "pi_4", "metadata" => { "ticket_item_id" => item.id } })
    StripeWebhookJob.perform_now(ev.id)

    assert_equal "cancelled", item.reload.status
    assert_equal quantity_after_release, @ticket.reload.quantity, "no double release / no oversell"
  end

  test "an event from another account's endpoint cannot touch an order it doesn't own" do
    # Attacker's own setting + endpoint; victim's pending order under @setting.
    attacker = create_user
    attacker_setting = StripeSetting.create!(user: attacker, name: "A", secret_key: "sk_live_a", webhook_secret: "whsec_a")
    victim_item = create_order(provider_ref: "cs_victim")

    # A validly-signed event from the ATTACKER's account, with crafted
    # metadata pointing at the victim's order.
    ev = StripeEvent.create!(id: "evt_cross", stripe_setting_id: attacker_setting.id,
      event_type: "checkout.session.completed",
      payload: { "data" => { "object" => {
        "id" => "cs_attacker", "payment_status" => "paid", "amount_total" => 1000, "currency" => "usd",
        "payment_intent" => "pi_attacker", "metadata" => { "ticket_item_id" => victim_item.id }
      } } })
    StripeWebhookJob.perform_now(ev.id)

    assert_equal "pending", victim_item.reload.status, "cross-account webhook must never confirm the order"
    assert_match "setting mismatch", ev.reload.error

    # Same for destructive paths: expired / refunded.
    ev2 = StripeEvent.create!(id: "evt_cross2", stripe_setting_id: attacker_setting.id,
      event_type: "checkout.session.expired",
      payload: { "data" => { "object" => { "id" => "cs_victim" } } })
    StripeWebhookJob.perform_now(ev2.id)
    assert_equal "pending", victim_item.reload.status
  end

  test "a paid session with no matching pending order is flagged as an orphan payment" do
    item = create_order(provider_ref: "cs_orphan", txhash: "pi_first")
    item.update!(status: "succeeded") # settled via a first session/intent

    ev = record_event("checkout.session.completed",
      { "id" => "cs_orphan2", "payment_status" => "paid", "amount_total" => 1000, "currency" => "usd",
        "payment_intent" => "pi_second", "metadata" => { "ticket_item_id" => item.id } })
    StripeWebhookJob.perform_now(ev.id)

    assert_equal "succeeded", item.reload.status
    assert_equal "pi_first", item.txhash, "the settled payment reference must not be overwritten"
    assert_match "orphan payment", ev.reload.error
  end

  test "checkout.session.expired times out a pending order and releases inventory once" do
    item = create_order(provider_ref: "cs_exp")
    ev = record_event("checkout.session.expired",
      { "id" => "cs_exp", "metadata" => { "ticket_item_id" => item.id } })

    StripeWebhookJob.perform_now(ev.id)
    assert_equal "timeout", item.reload.status
    assert_equal 6, @ticket.reload.quantity

    # duplicate delivery of the same expiry → no double release
    ev2 = record_event("checkout.session.expired",
      { "id" => "cs_exp", "metadata" => { "ticket_item_id" => item.id } })
    StripeWebhookJob.perform_now(ev2.id)
    assert_equal 6, @ticket.reload.quantity
  end

  test "group ticket confirmation via webhook auto-joins the buyer" do
    group_event = create_group_ticket_event(group: @group, owner: @owner)
    group_ticket = create_ticket(event: group_event, ticket_type: "group", group_id: @group.id)
    item = TicketItem.create!(ticket: group_ticket, event: group_event, user: @buyer,
      ticket_type: "group", group_id: @group.id, status: "pending", amount: 1000,
      currency: "usd", payment_provider: "stripe", stripe_setting_id: @setting.id, provider_ref: "cs_g")
    assert_not @group.memberships.exists?(user: @buyer)

    ev = record_event("checkout.session.completed",
      { "id" => "cs_g", "payment_status" => "paid", "amount_total" => 1000, "currency" => "usd",
        "payment_intent" => "pi_g", "metadata" => { "ticket_item_id" => item.id } })
    StripeWebhookJob.perform_now(ev.id)

    assert_equal "succeeded", item.reload.status
    assert @group.memberships.exists?(user: @buyer)
  end

  test "charge.refunded finalizes a full refund: seat, coupon, participant, membership all released" do
    coupon = create_coupon(event: @event, code: "USED", discount_type: "amount", discount: 100, order_usage_count: 1)
    participant = Participant.create!(user: @buyer, event: @event, status: "attending", payment_status: "succeeded")
    @event.update!(participant_count: 1)
    item = create_order(status: "succeeded", txhash: "pi_r", coupon_id: coupon.id,
      participant_id: participant.id, ticket_type: "group", group_id: @group.id)
    @group.add_member(@buyer.id, "member")
    refund = item.refunds.create!(requested_by: @owner, amount: 1000, full_refund: true, provider_ref: "re_1")

    ev = record_event("charge.refunded",
      { "payment_intent" => "pi_r", "refunds" => { "data" => [ { "id" => "re_1" } ] } })
    StripeWebhookJob.perform_now(ev.id)

    assert_equal "succeeded", refund.reload.status
    assert_equal "refunded", item.reload.status
    assert_equal 6, @ticket.reload.quantity
    assert_equal 0, coupon.reload.order_usage_count
    assert_equal 0, @event.reload.participant_count
    assert_equal "cancelled", participant.reload.status
    assert_not @group.memberships.exists?(user_id: @buyer.id, role: "member"),
      "the auto-joined membership must be revoked on full refund"
  end

  test "a partial refund moves money only — seat and membership stay" do
    item = create_order(status: "succeeded", txhash: "pi_p", ticket_type: "group", group_id: @group.id)
    @group.add_member(@buyer.id, "member")
    refund = item.refunds.create!(requested_by: @owner, amount: 300, full_refund: false, provider_ref: "re_2")

    ev = record_event("charge.refunded",
      { "payment_intent" => "pi_p", "refunds" => { "data" => [ { "id" => "re_2" } ] } })
    StripeWebhookJob.perform_now(ev.id)

    assert_equal "succeeded", refund.reload.status
    assert_equal "partially_refunded", item.reload.status
    assert_equal 5, @ticket.reload.quantity, "partial refund must not release the seat"
    assert @group.memberships.exists?(user_id: @buyer.id, role: "member")
  end

  test "a dashboard-issued refund (no local row) creates the refund record and applies side effects" do
    item = create_order(status: "succeeded", txhash: "pi_dash")
    assert_equal 0, item.refunds.count

    ev = record_event("charge.refunded",
      { "payment_intent" => "pi_dash", "amount_refunded" => 1000,
        "refunds" => { "data" => [ { "id" => "re_dash", "amount" => 1000 } ] } })
    StripeWebhookJob.perform_now(ev.id)

    refund = item.refunds.sole
    assert_equal "succeeded", refund.status
    assert refund.full_refund
    assert_equal "re_dash", refund.provider_ref
    assert_equal @setting.user_id, refund.requested_by_user_id, "attributed to the Stripe account holder"
    assert_equal "refunded", item.reload.status
    assert_equal 6, @ticket.reload.quantity

    # replayed delivery → no double release, no duplicate row
    ev2 = record_event("charge.refunded",
      { "payment_intent" => "pi_dash", "amount_refunded" => 1000,
        "refunds" => { "data" => [ { "id" => "re_dash", "amount" => 1000 } ] } })
    StripeWebhookJob.perform_now(ev2.id)
    assert_equal 1, item.refunds.count
    assert_equal 6, @ticket.reload.quantity
  end

  test "dispute lifecycle: created marks disputed; closed resolves won back to succeeded, lost to refunded" do
    won = create_order(status: "succeeded", txhash: "pi_won")
    ev = record_event("charge.dispute.created", { "payment_intent" => "pi_won" })
    StripeWebhookJob.perform_now(ev.id)
    assert_equal "disputed", won.reload.status

    ev = record_event("charge.dispute.closed", { "payment_intent" => "pi_won", "status" => "won" })
    StripeWebhookJob.perform_now(ev.id)
    assert_equal "succeeded", won.reload.status

    lost = create_order(status: "succeeded", txhash: "pi_lost")
    record_and_run = ->(type, obj) { StripeWebhookJob.perform_now(record_event(type, obj).id) }
    record_and_run.call("charge.dispute.created", { "payment_intent" => "pi_lost" })
    record_and_run.call("charge.dispute.closed", { "payment_intent" => "pi_lost", "status" => "lost" })
    assert_equal "refunded", lost.reload.status
    assert lost.released_at.present?, "a lost dispute releases the seat like a full refund"
  end
end
