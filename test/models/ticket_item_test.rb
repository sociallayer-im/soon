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
end
