require "test_helper"

class GroupMailerTest < ActionMailer::TestCase
  test "invite addresses the invitee and names the group and sender" do
    owner = create_user(name: "host-user")
    group = create_group(owner: owner, nickname: "The Guild")
    invite = create_group_invite(group: group, sender: owner, role: "member",
      receiver_address_type: "email", receiver_address: "invitee@test.com", message: "join us")

    mail = GroupMailer.invite(invite_id: invite.id)

    assert_equal ["invitee@test.com"], mail.to
    assert_equal "You're invited to join The Guild", mail.subject
    assert_match "The Guild", mail.html_part.body.to_s
    assert_match "host-user", mail.html_part.body.to_s
    assert_match "join us", mail.html_part.body.to_s
  end

  test "ticket_purchased goes to the given recipient and names the group" do
    owner = create_user
    group = create_group(owner: owner, nickname: "Ticketed")
    event = create_event(group: group, owner: owner)
    ticket = create_ticket(event: event, title: "GA")
    buyer = create_user(name: "buyer-user")
    item = TicketItem.create!(ticket: ticket, event: event, user: buyer, group: group,
      ticket_type: "group", status: "succeeded", amount: 500, original_price: 500)

    mail = GroupMailer.ticket_purchased(ticket_item_id: item.id, recipient: owner.email)

    assert_equal [owner.email], mail.to
    assert_equal "New ticket purchase — Ticketed", mail.subject
    assert_match "GA", mail.html_part.body.to_s
    assert_match "buyer-user", mail.html_part.body.to_s
  end

  test "registered names the new group, its handle and its owner" do
    owner = create_user(name: "founder-user")
    group = create_group(owner: owner, nickname: "Fresh Start", bio: "we do things")

    mail = GroupMailer.registered(group_id: group.id, recipient: "admin@test.com")

    assert_equal ["admin@test.com"], mail.to
    assert_equal "New group: Fresh Start", mail.subject
    assert_match "founder-user", mail.html_part.body.to_s
    assert_match group.name, mail.html_part.body.to_s
    assert_match "we do things", mail.html_part.body.to_s
    assert_match "founder-user", mail.text_part.body.to_s
  end

  test "registered renders for a group whose owner row is gone" do
    group = create_group # no owner membership at all

    mail = GroupMailer.registered(group_id: group.id, recipient: "admin@test.com")

    assert_match group.name, mail.html_part.body.to_s
  end
end
