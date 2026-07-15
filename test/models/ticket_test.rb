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

  test "inherit_group_ticket_type sets ticket_type and group_id from a kind=='group_ticket' event" do
    group_ticket_event = create_event(group: @group, owner: @owner, kind: "group_ticket")
    ticket = create_ticket(event: group_ticket_event)
    assert_equal "group", ticket.ticket_type
    assert_equal @group.id, ticket.group_id
  end
end
