class GroupMailer < ApplicationMailer
  # Emailed to a would-be member when a manager invites an address that has no
  # account yet (GroupInvite with receiver_address_type "email").
  def invite(invite_id:)
    @invite = GroupInvite.find(invite_id)
    @group  = @invite.group
    @accept_url = "#{WEB_URL}/group/join/#{@group.name}?invite=#{@invite.id}"
    mail(to: @invite.receiver_address, subject: "You're invited to join #{@group.display_name}")
  end

  # Notifies a group's owner that one of their group tickets was purchased.
  def ticket_purchased(ticket_item_id:, recipient:)
    @ticket_item = TicketItem.find(ticket_item_id)
    @group = @ticket_item.group
    @buyer = @ticket_item.user
    mail(to: recipient, subject: "New ticket purchase — #{@group.display_name}")
  end
end
