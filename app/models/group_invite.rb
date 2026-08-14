class GroupInvite < ApplicationRecord
  belongs_to :sender, class_name: "User", optional: true
  belongs_to :receiver, class_name: "User", optional: true
  belongs_to :group
  belongs_to :badge_class, optional: true
  belongs_to :badge, optional: true
  belongs_to :ticket, optional: true

  # Must match Membership's role vocabulary exactly — an invite's role is passed
  # straight through to Group#add_member on acceptance, so any value valid here
  # but not there would silently fail to grant membership.
  validates :role, inclusion: { in: %w(member manager owner) }

  enum :status, { sending: "sending", requesting: "requesting", accepted: "accepted", cancelled: "cancelled", revoked: "revoked" }

  # NULL expires_at means "never expires" (see #expired?), so it must pass here too —
  # ticket grants (see #grant_ticket!) are created with no expiry since the ticket was
  # already paid for and shouldn't lapse just because signup is delayed.
  scope :pending_for_email, ->(email) { where(status: "sending", receiver_address_type: "email", receiver_address: email).where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :pending_for_phone, ->(phone) { where(status: "sending", receiver_address_type: "phone", receiver_address: phone).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  # Runs the side effects of accepting: always grants membership; a ticket
  # invite (a manager-granted paid group ticket — see
  # TicketsController#add_group_ticket_item) also mints the TicketItem grant.
  # `user` is the person becoming the member — for a self-service join
  # request this is the original requester, not whoever approves it.
  # Accepting must never DEMOTE: an invite minted while the person had no
  # account (or an unbound phone) can be accepted long after they became a
  # manager or owner through some other path, and add_member overwrites the
  # role unconditionally. Keep whichever role ranks higher.
  ROLE_RANK = { "member" => 0, "manager" => 1, "owner" => 2 }.freeze

  def accept!(user)
    transaction do
      existing = group.memberships.find_by(user_id: user.id)
      unless existing && ROLE_RANK.fetch(existing.role, 0) >= ROLE_RANK.fetch(role, 0)
        group.add_member(user.id, role)
      end
      grant_ticket!(user) if ticket_id.present?
      update!(status: "accepted", receiver_id: user.id)
    end
  end

  # Auto-run whenever a user's email becomes verified (signup, wallet bind_email,
  # Google sign-in) — see AuthController. Only ticket invites auto-accept: the
  # ticket was already paid for, so the grant should land the moment the
  # recipient's email is verified. Plain group invites stay pending for the
  # user to accept manually (GroupInvitesController#pending/#accept) — money
  # already changed hands for a ticket, but a plain invite is still a choice.
  def self.auto_accept_ticket_invites_for(user)
    return unless user.email.present?
    pending_for_email(user.email).where.not(ticket_id: nil).find_each { |invite| invite.accept!(user) }
  end

  # Phone invites auto-accept UNCONDITIONALLY, ticket or not — the opposite of
  # the email rule above, on purpose. A phone invite only ever comes from a
  # manager importing a member whitelist (there is no mail to send and no SMS
  # is sent), so the intent is "these people already ARE members" and the join
  # should land the moment the number is verified — sign-in or bind alike.
  # Called from AuthController#verify_phone_code, #bind_phone and the account
  # merge (which can carry a verified phone onto the surviving account).
  def self.auto_accept_phone_invites_for(user)
    return unless user.phone.present?
    pending_for_phone(user.phone).find_each do |invite|
      # This runs INSIDE sign-in (verify_phone_code / bind_phone). One broken
      # invite must not lock the account out of logging in forever — it stays
      # pending for a retry on the next sign-in instead.
      invite.accept!(user)
    rescue StandardError => e
      Rails.logger.error("[group_invite] phone auto-accept failed for invite #{invite.id}: #{e.message}")
    end
  end

  private

  def grant_ticket!(user)
    item = TicketItem.create_with(status: "pending").find_or_create_by!(
      event_id: group.group_ticket_event_id, ticket_id: ticket_id,
      selector_type: receiver_address_type, selector_address: receiver_address,
      ticket_type: "group", group_id: group_id, auth_type: "invite"
    )
    item.update!(status: "succeeded", user_id: user.id) unless item.status == "succeeded"
  end
end
