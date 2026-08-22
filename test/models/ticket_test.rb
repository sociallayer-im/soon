require "test_helper"

class TicketTest < ActiveSupport::TestCase
  def setup
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
  end

  test "reserve! on unlimited (nil quantity) always succeeds and never changes quantity" do
    ticket = create_ticket(event: @event, quantity: nil)
    assert ticket.reserve!
    assert_nil ticket.reload.quantity
  end

  test "reserve! on quantity 1 succeeds once then fails, without going negative" do
    ticket = create_ticket(event: @event, quantity: 1)
    assert ticket.reserve!
    assert_equal 0, ticket.reload.quantity

    assert_not ticket.reserve!
    assert_equal 0, ticket.reload.quantity
  end

  test "release! increments quantity back" do
    ticket = create_ticket(event: @event, quantity: 1)
    ticket.reserve!
    assert_equal 0, ticket.reload.quantity

    ticket.release!
    assert_equal 1, ticket.reload.quantity
  end

  test "release! on unlimited (nil quantity) is a no-op" do
    ticket = create_ticket(event: @event, quantity: nil)
    ticket.release!
    assert_nil ticket.reload.quantity
  end

  test "the DB CHECK constraint rejects a negative quantity even if application code is bypassed" do
    ticket = create_ticket(event: @event, quantity: 0)

    assert_raises(ActiveRecord::StatementInvalid) do
      Ticket.connection.execute("UPDATE tickets SET quantity = -1 WHERE id = '#{ticket.id}'")
    end
  end

  test "status and ticket_type inclusion validations" do
    ticket = Ticket.new(event: @event, status: "bogus", ticket_type: "bogus")
    assert_not ticket.valid?
    assert_includes ticket.errors[:status], "is not included in the list"
    assert_includes ticket.errors[:ticket_type], "is not included in the list"
  end

  test "inherit_group_ticket_type sets ticket_type and group_id on the group's designated ticket event" do
    group_ticket_event = create_group_ticket_event(group: @group, owner: @owner)
    ticket = create_ticket(event: group_ticket_event)
    assert_equal "group", ticket.ticket_type
    assert_equal @group.id, ticket.group_id
  end

  test "inherit_group_ticket_type still sets group_id but does not clobber an explicit membership_card type" do
    group_ticket_event = create_group_ticket_event(group: @group, owner: @owner)
    ticket = create_ticket(event: group_ticket_event, ticket_type: "membership_card")
    assert_equal "membership_card", ticket.ticket_type
    assert_equal @group.id, ticket.group_id
  end

  test "a group/membership_card ticket cannot point group_id at a group other than the event's own" do
    other_group = create_group
    # @event belongs to @group, NOT other_group — nothing about @event grants
    # authority over other_group, so a ticket here must not be able to grant
    # membership there.
    %w[group membership_card].each do |type|
      ticket = Ticket.new(event: @event, title: "t", ticket_type: type, group_id: other_group.id)
      assert_not ticket.valid?, "#{type} ticket should reject a group_id that isn't the event's own group"
      assert_includes ticket.errors[:group_id], "must be the event's own group for a #{type} ticket"
    end
  end

  test "an event ticket_type ticket is unaffected by the group_id/event-group check" do
    other_group = create_group
    ticket = Ticket.new(event: @event, title: "t", ticket_type: "event", group_id: other_group.id)
    assert ticket.valid?, ticket.errors.full_messages.join(", ")
  end
end
