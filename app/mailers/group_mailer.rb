class GroupMailer < ApplicationMailer
  # Emailed to a would-be member when a manager invites an address that has no
  # account yet (GroupInvite with receiver_address_type "email").
  def invite(invite_id:)
    @invite = GroupInvite.find(invite_id)
    @group  = @invite.group
    @accept_url = "#{WEB_URL}/group/join/#{@group.name}?invite=#{@invite.id}"
    mail(to: @invite.receiver_address, subject: "You're invited to join #{@group.display_name}")
  end

  # A manager's broadcast to the group's members (the "email members" page).
  # Subject/content are manager-authored; content is plain text.
  def member_broadcast(group_id:, subject:, content:, recipient:)
    @group = Group.find(group_id)
    @content = content
    mail(to: recipient, subject: subject)
  end

  # Tells a platform admin that a group just registered. Fanned out by
  # GroupRegisteredMailJob, one delivery per admin address.
  def registered(group_id:, recipient:)
    @group = Group.find(group_id)
    @owner = @group.memberships.includes(:user).find_by(role: "owner")&.user
    @group_url = "#{WEB_URL}/group/#{@group.name}"
    mail(to: recipient, subject: "New group: #{@group.display_name}")
  end

  # Notifies a group's owner that one of their group tickets was purchased.
  def ticket_purchased(ticket_item_id:, recipient:)
    @ticket_item = TicketItem.find(ticket_item_id)
    @group = @ticket_item.group
    @buyer = @ticket_item.user
    mail(to: recipient, subject: "New ticket purchase — #{@group.display_name}")
  end

  # Tells a platform admin that a manager/owner just requested a WeChat Pay
  # withdrawal. Fanned out by WithdrawalRequestedMailJob, one delivery per
  # admin address — withdrawals move real money out of the platform's pooled
  # account, so an admin should hear about every request as it happens rather
  # than discovering it later in the ledger.
  def withdrawal_requested(withdrawal_id:, recipient:)
    @withdrawal = Withdrawal.find(withdrawal_id)
    @group = @withdrawal.group
    @requester = @withdrawal.user
    mail(to: recipient, subject: "Withdrawal requested — #{@group.display_name}")
  end
end
