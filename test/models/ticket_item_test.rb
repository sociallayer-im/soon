require "test_helper"

class TicketItemTest < ActiveSupport::TestCase
  include FactoryHelpers

  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @ticket = create_ticket(event: @event, quantity: 5)
    @buyer = create_user
  end

  def build_item(status: "pending", **attrs)
    TicketItem.create!({ ticket: @ticket, event: @event, user: @buyer,
      ticket_type: "event", status: status, amount: 1000 }.merge(attrs))
  end

  test "transition! enforces the allowed-transition table" do
    item = build_item
    item.transition!(:succeeded)
    assert_equal "succeeded", item.status

    # succeeded is not cancellable — cancel/timeout are pending-only exits
    assert_raises TicketItem::InvalidTransition do
      item.transition!(:cancelled)
    end
  end

  test "terminal states allow no further transitions" do
    %w[cancelled timeout refunded].each do |terminal|
      item = build_item(status: "pending")
      item.update!(status: terminal) # bypass to set up the terminal state
      assert_raises(TicketItem::InvalidTransition, "#{terminal} must be terminal") do
        item.transition!(:succeeded)
      end
    end
  end

  test "disputed can resolve back to succeeded (dispute won) or to refunded (lost)" do
    won = build_item(status: "succeeded")
    won.transition!(:disputed)
    won.transition!(:succeeded)
    assert_equal "succeeded", won.status

    lost = build_item(status: "succeeded")
    lost.transition!(:disputed)
    lost.transition!(:refunded)
    assert_equal "refunded", lost.status
  end

  test "release_resources! hands inventory back exactly once, guarded by released_at" do
    coupon = create_coupon(event: @event, code: "ONCE", discount_type: "amount", discount: 100, order_usage_count: 1)
    @event.update!(participant_count: 1)
    item = build_item(coupon_id: coupon.id)

    item.release_resources!
    assert item.released_at.present?
    assert_equal 6, @ticket.reload.quantity
    assert_equal 0, coupon.reload.order_usage_count
    # The seat is NOT this method's to give back: it belongs to the
    # participant's status, and one person can hold several orders. Releasing
    # per order took a seat away that the order never occupied.
    assert_equal 1, @event.reload.participant_count

    # A second release path (late webhook, sweeper overlap) is a no-op.
    item.release_resources!
    assert_equal 6, @ticket.reload.quantity
    assert_equal 0, coupon.reload.order_usage_count
    assert_equal 1, @event.reload.participant_count
  end

  test "cancel releases resources and a later timeout raises instead of double-releasing" do
    item = build_item
    item.cancel
    assert_equal "cancelled", item.status
    assert_equal 6, @ticket.reload.quantity

    assert_raises(TicketItem::InvalidTransition) { item.timeout }
    assert_equal 6, @ticket.reload.quantity
  end

  test "confirm_payment! stamps paid_at" do
    item = build_item
    item.confirm_payment!
    assert_equal "succeeded", item.status
    assert item.paid_at.present?
  end

  test "confirm_payment! on a membership_card grants a 30-day membership" do
    item = build_item(ticket_type: "membership_card", group: @group)
    item.confirm_payment!

    membership = @group.memberships.find_by(user_id: @buyer.id)
    assert membership.present?
    assert_equal "member", membership.role
    assert_in_delta 30.days.from_now.to_i, membership.expires_at.to_i, 5
  end

  test "confirm_payment! on a repeat membership_card purchase stacks onto the existing expiry" do
    item1 = build_item(ticket_type: "membership_card", group: @group)
    item1.confirm_payment!
    first_expiry = @group.memberships.find_by(user_id: @buyer.id).expires_at

    item2 = build_item(ticket_type: "membership_card", group: @group)
    item2.confirm_payment!
    second_expiry = @group.memberships.find_by(user_id: @buyer.id).expires_at

    assert_in_delta (first_expiry + 30.days).to_i, second_expiry.to_i, 5
  end

  test "confirm_payment! on the SAME order does not re-extend membership on a repeat call" do
    # Payment providers deliver webhooks at-least-once; confirm_payment! is
    # explicitly written to tolerate a repeat call for an order that already
    # succeeded (see the newly_paid guard) — the membership grant must not
    # re-fire on that repeat call, or a retried webhook stacks a free extra
    # duration onto a single purchase.
    item = build_item(ticket_type: "membership_card", group: @group)
    item.confirm_payment!
    first_expiry = @group.memberships.find_by(user_id: @buyer.id).expires_at

    item.confirm_payment!
    second_expiry = @group.memberships.find_by(user_id: @buyer.id).expires_at

    assert_in_delta first_expiry.to_i, second_expiry.to_i, 5
  end

  test "confirm_payment! honours the ticket's own membership_duration_days, not a fixed 30" do
    weekly = create_ticket(event: @event, group_id: @group.id, ticket_type: "membership_card",
      membership_duration_days: 7)
    item = build_item(ticket: weekly, ticket_type: "membership_card", group: @group)
    item.confirm_payment!

    membership = @group.memberships.find_by(user_id: @buyer.id)
    assert_in_delta 7.days.from_now.to_i, membership.expires_at.to_i, 5
  end

  test "confirm_payment! stacks durations from different tiers on the same buyer" do
    weekly = create_ticket(event: @event, group_id: @group.id, ticket_type: "membership_card",
      membership_duration_days: 7)
    yearly = create_ticket(event: @event, group_id: @group.id, ticket_type: "membership_card",
      membership_duration_days: 365)

    build_item(ticket: weekly, ticket_type: "membership_card", group: @group).confirm_payment!
    first_expiry = @group.memberships.find_by(user_id: @buyer.id).expires_at

    build_item(ticket: yearly, ticket_type: "membership_card", group: @group).confirm_payment!
    second_expiry = @group.memberships.find_by(user_id: @buyer.id).expires_at

    assert_in_delta (first_expiry + 365.days).to_i, second_expiry.to_i, 5
  end

  test "confirm_payment! on a lapsed membership_card starts a fresh 30 days from now, not from the old expiry" do
    @group.memberships.create!(user_id: @buyer.id, role: "member", expires_at: 5.days.ago)

    item = build_item(ticket_type: "membership_card", group: @group)
    item.confirm_payment!

    membership = @group.memberships.find_by(user_id: @buyer.id)
    assert_in_delta 30.days.from_now.to_i, membership.expires_at.to_i, 5
  end

  test "confirm_payment! on a membership_card is a no-op for an existing manager" do
    @group.memberships.create!(user_id: @buyer.id, role: "manager")

    item = build_item(ticket_type: "membership_card", group: @group)
    item.confirm_payment!

    membership = @group.memberships.find_by(user_id: @buyer.id)
    assert_equal "manager", membership.role
    assert_nil membership.expires_at
  end

  test "confirm_payment! on a group ticket upgrades a lapsed membership_card member to permanent" do
    @group.memberships.create!(user_id: @buyer.id, role: "member", expires_at: 5.days.ago)
    group_ticket = create_ticket(event: @event, group_id: @group.id, ticket_type: "group")

    item = build_item(ticket: group_ticket, ticket_type: "group", group: @group)
    item.confirm_payment!

    membership = @group.memberships.find_by(user_id: @buyer.id)
    assert_nil membership.expires_at
  end
end
