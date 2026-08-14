class Api::V1::GroupInvitesController < Api::BaseController
  before_action :set_group, except: %i[pending show]
  before_action :set_invite, only: %i[destroy accept accept_request revoke]

  rescue_from ActiveRecord::RecordInvalid do |e|
    render_error(e.record.errors.full_messages.join(", "))
  end

  INVITE_TTL = 30.days

  # GET /api/v1/groups/:group_id/group_invites
  def index
    authorize @group, :update?, policy_class: GroupPolicy
    render_collection @group.group_invites, blueprint: GroupInviteBlueprint
  end

  # GET /api/v1/group_invites/pending
  def pending
    invites = GroupInvite.pending_for_email(current_user.email).includes(:group, :sender)
    render json: GroupInviteBlueprint.render(invites)
  end

  # GET /api/v1/group_invites/:id
  #
  # Standalone lookup for the invite-preview page (/invite/:id), which has no
  # group_id in its URL. See GroupInvitePolicy#view? for who may see what.
  def show
    invite = GroupInvite.find(params[:id])
    authorize invite, :view?
    render json: GroupInviteBlueprint.render(invite)
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # POST /api/v1/groups/:group_id/group_invites
  #
  # Known users are added to the group directly (no invite record created).
  # Only email addresses with no matching user get a real GroupInvite.
  def create
    authorize @group, :update?, policy_class: GroupPolicy

    role = params[:role].presence || "member"
    results = Array(params[:receivers]).map { |address| send_invite_to(address, role) }
    render json: { results: results }
  end

  # DELETE /api/v1/groups/:group_id/group_invites/:id
  def destroy
    authorize @invite, :cancel?
    @invite.update(status: "cancelled")
    head :no_content
  end

  # POST /api/v1/groups/:group_id/group_invites/:id/revoke
  def revoke
    authorize @invite, :revoke?
    @invite.update(status: "revoked")
    render json: GroupInviteBlueprint.render(@invite)
  end

  # POST /api/v1/groups/:group_id/group_invites/:id/accept
  #
  # Recipient accepts an email invite.
  def accept
    unless @invite.status == "sending" && @invite.receiver_address == current_user.email
      return render_error("invite is not for this user")
    end
    return render_error("invite expired") if @invite.expired?

    @invite.accept!(current_user)
    render json: GroupInviteBlueprint.render(@invite)
  end

  # POST /api/v1/groups/:group_id/group_invites/:id/accept_request
  #
  # Manager approves a self-service join request. The member being granted is
  # whoever requested (@invite.receiver_id), not the approving manager.
  def accept_request
    authorize @group, :update?, policy_class: GroupPolicy
    return render_error("invite is not a pending request") unless @invite.status == "requesting"
    return render_error("request expired") if @invite.expired?

    @invite.accept!(User.find(@invite.receiver_id))
    render json: GroupInviteBlueprint.render(@invite)
  end

  # POST /api/v1/groups/:group_id/group_invites/request_invite
  #
  # Self-service join request.
  def request_invite
    if @group.memberships.exists?(user_id: current_user.id)
      return render_error("already a member")
    end
    pending = GroupInvite.find_by(group: @group, receiver_id: current_user.id, status: "requesting")
    if pending
      return render_error("request already pending") unless pending.expired?
      pending.update(status: "cancelled")
    end

    invite = GroupInvite.create(group: @group, receiver_id: current_user.id, status: "requesting", role: "member",
      expires_at: INVITE_TTL.from_now)
    render json: GroupInviteBlueprint.render(invite), status: :created
  end

  # POST /api/v1/groups/:group_id/group_invites/send_with_code
  #
  # Manager generates a reusable invite code. Status never flips to accepted — it's reusable.
  def send_with_code
    authorize @group, :update?, policy_class: GroupPolicy

    role = params[:role].presence || "member"
    code = SecureRandom.alphanumeric(8).upcase
    invite = GroupInvite.create(
      group: @group, sender: current_user, role: role,
      receiver_address_type: "code", receiver_address: code,
      status: "sending", expires_at: INVITE_TTL.from_now, message: params[:message]
    )
    render json: GroupInviteBlueprint.render(invite), status: :created
  end

  # POST /api/v1/groups/:group_id/group_invites/accept_with_code
  def accept_with_code
    invite = @group.group_invites.find_by(receiver_address_type: "code", receiver_address: params[:code])
    return render_error("invalid code") unless invite
    return render_error("code expired") if invite.expired?

    existing = @group.memberships.exists?(user_id: current_user.id)
    @group.add_member(current_user.id, invite.role)
    action = existing ? "group_invite/update_role" : "group_invite/add_member"
    Activity.create(item: invite, initiator: current_user, action: action,
      payload: { group_name: @group.name, group_display_name: @group.display_name })
    render json: GroupInviteBlueprint.render(invite)
  end

  private

  def set_group
    @group = Group.find(params[:group_id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def set_invite
    @invite = @group.group_invites.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def send_invite_to(address, role)
    # Normalized with the SAME rules sign-in uses (PhoneNumber ⊂ AuthController)
    # — the invite has to match users.phone verbatim for auto-join to find it.
    phone = PhoneNumber.normalize(address)
    # Phone match comes FIRST when the input reads as one: usernames may be
    # all digits, and a user NAMED "13800138000" must not intercept an invite
    # meant for whoever owns that number.
    user = User.find_by(phone: phone) if phone
    user ||= User.find_by(name: address) || User.find_by(email: address) || User.find_by(eth: address)

    if user
      membership = @group.memberships.find_by(user_id: user.id)
      if membership && membership.role == "member" && role != "member"
        membership.update!(role: role)
        Activity.create(item: membership, initiator: current_user, action: "group_invite/update_role", receiver: user,
          payload: { message: params[:message], group_name: @group.name, group_display_name: @group.display_name })
        return { address: address, result: "role_updated" }
      elsif membership
        return { address: address, result: "error", message: "membership exists" }
      else
        membership = @group.add_member(user.id, role)
        Activity.create(item: membership, initiator: current_user, action: "group_invite/send", receiver: user,
          payload: { message: params[:message], group_name: @group.name, group_display_name: @group.display_name })
        return { address: address, result: "added" }
      end
    elsif address.to_s.include?("@")
      invite = GroupInvite.create!(
        group: @group, sender: current_user, role: role,
        receiver_address_type: "email", receiver_address: address,
        status: "sending", expires_at: INVITE_TTL.from_now,
        message: params[:message]
      )
      GroupMailer.invite(invite_id: invite.id).deliver_later
      return { address: address, result: "invited" }
    elsif phone
      # Re-importing a list that overlaps the last one is the normal case —
      # an existing pending invite for the number is success, not a duplicate.
      if @group.group_invites.pending_for_phone(phone).exists?
        return { address: address, result: "invited" }
      end
      # A member whitelist import. No mail exists to send and no SMS is sent
      # (invite templates aren't registered with the gateway) — the person
      # simply becomes a member the moment they sign in with, or bind, this
      # number (GroupInvite.auto_accept_phone_invites_for). No expiry for the
      # same reason: a whitelist isn't an offer that lapses, and the holder
      # gets no notification that would prompt them to hurry.
      GroupInvite.create!(
        group: @group, sender: current_user, role: role,
        receiver_address_type: "phone", receiver_address: phone,
        status: "sending", expires_at: nil,
        message: params[:message]
      )
      return { address: address, result: "invited" }
    else
      return { address: address, result: "error", message: "invalid receiver" }
    end
  rescue ActiveRecord::RecordInvalid => e
    { address: address, result: "error", message: e.record.errors.full_messages.join(", ") }
  end
end
