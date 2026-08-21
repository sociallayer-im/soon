require "test_helper"

class WithdrawalTest < ActiveSupport::TestCase
  include FactoryHelpers

  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @ticket = create_ticket(event: @event, quantity: 10)
    @buyer = create_user
  end

  def build_item(status: "succeeded", amount: 10_000, **attrs)
    TicketItem.create!({
      ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: status, amount: amount, currency: "cny", payment_provider: "wechat"
    }.merge(attrs))
  end

  def create_withdrawal(group:, user:, status: "pending", amount: 100, **attrs)
    Withdrawal.create!({
      group: group, user: user, amount: amount, currency: "cny", status: status,
      bank_name: "x", bank_account_number: "1", bank_account_name: "a"
    }.merge(attrs))
  end

  test "available_balance is 96% of gross wechat revenue for the group" do
    build_item(amount: 10_000)
    assert_equal 9_600, Withdrawal.available_balance(@group)
  end

  test "available_balance nets out succeeded refunds, not just full-refunded orders" do
    item = build_item(status: "partially_refunded", amount: 10_000)
    Refund.create!(ticket_item: item, requested_by: @owner, amount: 4_000, status: "succeeded")

    # net = 10_000 - 4_000 = 6_000; 96% of that = 5_760 — NOT 96% of the
    # original 10_000 (9_600), which would hand out money already refunded.
    assert_equal 5_760, Withdrawal.available_balance(@group)
  end

  test "a pending refund does not reduce the balance yet" do
    item = build_item(status: "partially_refunded", amount: 10_000)
    Refund.create!(ticket_item: item, requested_by: @owner, amount: 4_000, status: "pending")

    assert_equal 9_600, Withdrawal.available_balance(@group)
  end

  test "fully refunded orders contribute nothing" do
    build_item(status: "refunded", amount: 10_000)
    assert_equal 0, Withdrawal.available_balance(@group)
  end

  test "non-wechat revenue is excluded" do
    build_item(payment_provider: "stripe", amount: 10_000)
    assert_equal 0, Withdrawal.available_balance(@group)
  end

  test "revenue from a different group is excluded" do
    build_item(amount: 10_000)
    other_group = create_group(owner: create_user)
    assert_equal 0, Withdrawal.available_balance(other_group)
  end

  test "already-requested (pending) withdrawals reduce the available balance" do
    build_item(amount: 10_000)
    create_withdrawal(group: @group, user: @owner, amount: 5_000, status: "pending")

    assert_equal 4_600, Withdrawal.available_balance(@group)
  end

  test "a rejected withdrawal frees the balance back up" do
    build_item(amount: 10_000)
    create_withdrawal(group: @group, user: @owner, amount: 9_600, status: "rejected")

    assert_equal 9_600, Withdrawal.available_balance(@group)
  end

  test "total_withdrawn only counts completed withdrawals" do
    create_withdrawal(group: @group, user: @owner, amount: 1_000, status: "pending")
    create_withdrawal(group: @group, user: @owner, amount: 2_000, status: "completed")
    create_withdrawal(group: @group, user: @owner, amount: 3_000, status: "rejected")

    assert_equal 2_000, Withdrawal.total_withdrawn(@group)
  end

  test "a group-ticket order (group_id set directly) is still counted once" do
    item = build_item(ticket_type: "group", group_id: @group.id)
    assert_equal 9_600, Withdrawal.available_balance(@group)
    assert_equal [ item.id ], Withdrawal.wechat_ticket_items(@group).pluck(:id)
  end

  test "the group's balance is shared across its managers — one manager's withdrawal reduces it for all" do
    manager = create_user
    create_membership(user: manager, group: @group, role: "manager")
    build_item(amount: 10_000)

    assert_equal 9_600, Withdrawal.available_balance(@group)
    create_withdrawal(group: @group, user: @owner, amount: Withdrawal.available_balance(@group))

    # The co-manager's view of the SAME group's balance reflects the
    # owner's withdrawal — balance is a property of the group, not of
    # whichever manager is asking.
    assert_equal 0, Withdrawal.available_balance(@group)
    assert Withdrawal.may_manage?(manager, @group)
  end

  test "may_manage? is false for a plain member" do
    member = create_user
    create_membership(user: member, group: @group, role: "member")
    assert_not Withdrawal.may_manage?(member, @group)
  end
end
