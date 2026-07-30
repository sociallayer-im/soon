require "test_helper"

class ParticipantTest < ActiveSupport::TestCase
  include FactoryHelpers

  setup do
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @user = create_user
  end

  def participant(status: "attending")
    create_participant(event: @event, user: @user, status: status)
  end

  test "transition! enforces the lifecycle table" do
    p = participant(status: "pending")
    p.transition!(:attending)
    assert_equal "attending", p.status

    # pending is only reachable from the undecided states, not from attending.
    assert_raises Participant::InvalidTransition do
      p.transition!(:pending)
    end
  end

  test "cancelling stamps cancelled_at and re-joining clears it" do
    p = participant
    p.transition!(:cancelled)
    assert p.cancelled_at.present?
    assert_not p.seated?

    p.transition!(:attending)
    assert_nil p.cancelled_at, "a re-joined participant is not carrying a withdrawal time"
    assert p.seated?
  end

  test "only attending occupies a seat" do
    assert_equal %w[attending], Participant::SEATED
    %w[pending declined maybe cancelled].each do |status|
      assert_not participant(status: status).seated?, "#{status} must not hold a seat"
      Participant.delete_all
    end
  end

  test "active excludes only the soft-deleted" do
    p = participant
    assert_includes Participant.active, p
    p.transition!(:cancelled)
    assert_not_includes Participant.active, p
  end

  test "refresh_payment_status! derives the summary from the orders" do
    p = participant
    ticket = create_ticket(event: @event)

    assert_nil p.refresh_payment_status!, "no orders means nothing to summarise"

    pending = TicketItem.create!(ticket: ticket, event: @event, user: @user, participant: p,
      ticket_type: "event", status: "pending", amount: 1000)
    assert_equal "pending", p.refresh_payment_status!

    TicketItem.create!(ticket: ticket, event: @event, user: @user, participant: p,
      ticket_type: "event", status: "succeeded", amount: 1000)
    assert_equal "succeeded", p.refresh_payment_status!,
      "one settled order is enough — it must not be masked by an unpaid one"

    p.ticket_items.update_all(status: "cancelled")
    assert_equal "cancelled", p.refresh_payment_status!
  end
end
