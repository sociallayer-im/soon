require "test_helper"

class RefundTest < ActiveSupport::TestCase
  include FactoryHelpers

  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @ticket = create_ticket(event: @event)
    @buyer = create_user
    @item = TicketItem.create!(ticket: @ticket, event: @event, user: @buyer,
      ticket_type: "event", status: "succeeded", amount: 1000)
  end

  test "only one live full refund per ticket_item (concurrent-click guard)" do
    Refund.create!(ticket_item: @item, requested_by: @owner, amount: 1000, full_refund: true)

    assert_raises ActiveRecord::RecordNotUnique do
      Refund.create!(ticket_item: @item, requested_by: @owner, amount: 1000, full_refund: true)
    end
  end

  test "a failed full refund does not block a retry" do
    Refund.create!(ticket_item: @item, requested_by: @owner, amount: 1000, full_refund: true, status: "failed")
    retried = Refund.create!(ticket_item: @item, requested_by: @owner, amount: 1000, full_refund: true)
    assert retried.persisted?
  end

  test "partial refunds are not constrained by the full-refund guard" do
    Refund.create!(ticket_item: @item, requested_by: @owner, amount: 200, full_refund: false)
    second = Refund.create!(ticket_item: @item, requested_by: @owner, amount: 300, full_refund: false)
    assert second.persisted?
  end
end
