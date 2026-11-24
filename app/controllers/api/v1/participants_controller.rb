class Api::V1::ParticipantsController < Api::BaseController
  class PaidRefundRequired < StandardError; end
  rescue_from PaidRefundRequired do
    render json: {error: "请先提交退出与退款申请，退款成功后会自动退出活动", code: "PAID_REFUND_REQUIRED"}, status: :unprocessable_entity
  end
  # Reading the attendee list is as public as reading the event: the same list
  # has always been embedded in GET /events/:id, which anonymous visitors may
  # call. Now that the detail page can ask for the event without it, that page
  # has to be able to fetch it separately — including for a signed-out visitor,
  # who could see it before.
  skip_before_action :authenticate!, only: %i[index]
  before_action :authenticate_optional!, only: %i[index]
  before_action :set_event

  # GET /api/v1/events/:event_id/participants
  #
  # Withdrawn participants are soft-deleted (status "cancelled") and must not
  # appear in the attendee list — before the soft delete they were removed
  # outright, so nothing downstream expects to see them.
  def index
    # Gate on the EVENT, which this action never did: a token was required but
    # nothing checked it against the event, so any signed-in user could list
    # the attendees of a draft or private one. Matching EventPolicy#show? ties
    # the list to the same visibility rule as the event that owns it.
    authorize @event, :show?
    scope = @event.participants.active
    scope = scope.where(status: "attending").where(payment_status: [nil, "succeeded"]) unless EventPolicy.new(current_user, @event).update?
    manager = EventPolicy.new(current_user, @event).update?
    return head :forbidden if params[:status] == "waitlisted" && !manager
    scope = scope.order(:waitlisted_at, :id) if params[:status] == "waitlisted"
    scope = scope.where(status: params[:status]) if manager && Participant::STATUSES.include?(params[:status])
    scope = scope.order(Arel.sql("CASE WHEN participants.status = 'pending' THEN 0 WHEN participants.status = 'awaiting_payment' THEN 1 ELSE 2 END"), registered_at: :desc, id: :desc)
    limit = params.fetch(:limit, PAGY_DEFAULT_LIMIT).to_i.clamp(1, PAGY_MAX_LIMIT)
    page_users = scope.limit(limit).offset([params.fetch(:page, 1).to_i - 1, 0].max * limit).pluck(:user_id)
    answers = {}
    if manager && @event.form_id
      FormSubmission.where(form_id: @event.form_id, user_id: page_users).includes(form_answers: :form_field).each do |submission|
        answers[submission.user_id] = submission.form_answers.reject { |a| a.form_field.for_admin }.map { |a| {label: a.form_field.label, value: a.value} }
      end
    end
    review_tickets = {}
    if manager
      TicketItem.where(event_id: @event.id, user_id: page_users).where.not(participant_id: nil).includes(:ticket).order(:created_at).each do |item|
        (review_tickets[item.participant_id] ||= []) << {id: item.id, title: item.ticket.title, amount: item.amount.to_i, currency: item.currency, status: item.status}
      end
    end
    render_collection scope.includes(:user), blueprint: ParticipantBlueprint, manager: manager, application_answers: answers, review_tickets: review_tickets
  end

  # POST /api/v1/events/:event_id/participants
  def create
    authorize @event, :join?
    return render_error("活动尚未开放报名或报名已结束") unless @event.registration_open?
    return render_error("请选择票种后报名") if @event.tickets.where(status: "normal").exists?

    if @event.form_id
      required_field_ids = FormField.where(form_id: @event.form_id, required: true, for_admin: false).pluck(:id)
      if required_field_ids.any?
        answers = Array(params[:form_answers])
        missing = required_field_ids.reject do |fid|
          answer = answers.find { |a| a[:field_id].to_s == fid.to_s }
          answer && answer[:value].present?
        end
        return render_error("missing required form fields") if missing.any?
      end
    end

    @event.with_lock do
      return render_error("活动尚未开放报名或报名已结束") unless @event.registration_open?
      return render_error("请选择票种后报名") if @event.tickets.where(status: "normal").exists?
      is_manager = current_user.memberships.active.exists?(group: @event.group, role: %w[manager owner])
      status = "attending"
      status = "pending" if @event.require_approval && !is_manager

      existing = @event.participants.find_by(user_id: current_user.id)
      # Re-joining after withdrawing REUSES the soft-deleted row — (user_id,
      # event_id) is unique, so a second insert would fail. A rejected applicant
      # may re-apply for the same reason a withdrawn one may re-join: neither
      # holds a seat, and "declined" is not meant to be a permanent ban — the
      # transition table has allowed declined → pending/attending all along, it
      # was only this guard that made it unreachable. Anything else that already
      # exists is still a duplicate join and rejected as before.
      return render json: ParticipantBlueprint.render(existing, own: true) if existing&.status == "waitlisted"
      if existing && !existing.status.in?(%w[cancelled declined maybe])
        return render_error("User can only participate once per event")
      end

      # registered_at is re-stamped on reuse: they signed up again, and the old
      # value would misreport when. It is set on this path at all because the
      # ticket flow always stamped it and the free/direct join never did,
      # leaving the signup time blank for exactly the events that have no
      # tickets.
      participant = existing || @event.participants.new(user: current_user)

      # Only a status that counts toward capacity needs the check — a "pending"
      # join (awaiting approval) doesn't occupy a seat yet, matching sails/'s
      # "only count confirmed attendees; pending waits until approval". A
      # cancelled row occupies nothing, so re-joining takes a seat like a first
      # join does.
      @event.promote_waitlist! if status == "attending"
      if status == "attending" && (err = capacity_error)
        return render_error(err) unless @event.waitlist_enabled?
        status = "waitlisted"
      end

      participant.waitlisted_at = status == "waitlisted" ? Time.current : nil
      participant.assign_attributes(status: status, registered_at: Time.current, checked_in_at: nil, cancelled_at: nil, reviewed_at: nil, reviewed_by: nil, review_reason: nil, cancellation_reason: nil, payment_due_at: nil)

      ActiveRecord::Base.transaction do
        participant.save!
        @event.increment!(:participant_count) if status == "attending"

        if @event.form_id
          # The submission's status has to follow the application's, or the
          # organizer's list keeps showing the old verdict. This matters now that
          # a REJECTED applicant may apply again: without it their submission
          # would still read "rejected" while the participant is back to
          # "pending", and the two views of one application would disagree.
          #
          # A submission is only created when there are answers, though — an
          # empty row for a form nobody filled in is not a response.
          submission = FormSubmission.find_by(form_id: @event.form_id, user_id: current_user.id)
          if params[:form_answers].present?
            submission ||= FormSubmission.new(form_id: @event.form_id, user_id: current_user.id)
            submission.submitted_at = Time.current
          end

          if submission
            submission.status = status == "pending" ? "pending" : "approved"
            submission.save!
            if params[:form_answers].present?
              FormBuilder.record_answers!(submission, params[:form_answers],
                                          FormField.where(form_id: @event.form_id, for_admin: false).pluck(:id))
            end
          end
        end
      end

      render json: ParticipantBlueprint.render(participant, own: true), status: :created
    end
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # PATCH /api/v1/events/:event_id/participants/:id
  def update
    return destroy if params.dig(:participant, :status) == "cancelled"

    participant = @event.participants.find(params[:id])
    unless participant.user_id == current_user.id
      return render json: { error: "Forbidden" }, status: :forbidden
    end

    new_status = params.dig(:participant, :status)
    # PATCH is retained for older clients, but must not provide a second
    # registration/payment/review entrance. All exits use the same teardown.
    unless new_status == "maybe"
      return render_error("请通过报名入口重新报名，审核及支付完成后将自动确认")
    end
    return render_error("只有已确认报名可以标记为可能参加") if participant.status != "attending"
    withdraw_participant!(participant, status: new_status)
    render json: ParticipantBlueprint.render(participant, own: true)
  rescue TicketItem::InvalidTransition, Stripe::StripeError => e
    render_error(e.message)
  rescue Participant::InvalidTransition => e
    render_error(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # DELETE /api/v1/events/:event_id/participants/:id
  #
  # A SOFT delete: the row is marked cancelled, never removed. Hard-deleting
  # it destroyed history, and ticket_items.participant_id is a foreign key —
  # so it also raised InvalidForeignKey on every ticketed event (free RSVPs
  # create an order too). Keeping the row preserves the audit trail and lets
  # a later refund still reach the participant.
  def destroy
    participant = @event.participants.find(params[:id])
    unless participant.user_id == current_user.id || EventPolicy.new(current_user, @event).update?
      return render json: { error: "Forbidden" }, status: :forbidden
    end
    withdraw_participant!(participant, require_refund: participant.user_id == current_user.id)
    head :no_content
  rescue TicketItem::InvalidTransition, Stripe::StripeError => e
    render_error(e.message)
  rescue Participant::InvalidTransition
    # Two withdrawals in flight at once — a double-click on the cancel button,
    # which is a thing people do to a button that reloads the page. The other
    # request already did it, so this one has nothing to report but success.
    head :no_content
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # POST /api/v1/events/:event_id/participants/:id/approve
  #
  # Event owner or group admin/owner moves a pending (requires-approval) participant to attending.
  def approve
    authorize @event, :update?
    participant = @event.participants.find(params[:id])
    RegistrationReview.approve!(participant, actor: current_user)
    EventMailer.participant_approved(participant_id: participant.id).deliver_later unless participant.status == "waitlisted"
    render json: ParticipantBlueprint.render(participant, own: true)
  rescue RegistrationReview::Error => e
    render_error(e.message)
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # POST /api/v1/events/:event_id/participants/:id/reject
  #
  # Event owner or group admin/owner declines a pending applicant.
  def reject
    authorize @event, :update?
    participant = @event.participants.find(params[:id])
    RegistrationReview.reject!(participant, actor: current_user, reason: params[:reason])
    EventMailer.participant_rejected(participant_id: participant.id).deliver_later
    render json: ParticipantBlueprint.render(participant, own: true)
  rescue RegistrationReview::Error => e
    render_error(e.message)
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # POST /api/v1/events/:event_id/participants/check_in
  #
  # Manager scans an attendee at the door: stamps checked_in_at on their
  # participant record. Idempotent — re-checking-in just re-stamps.
  # Deliberately NOT registered_at, which is the RSVP timestamp: sharing one
  # column made every registrant look checked in.
  def check_in
    authorize @event, :update?
    participant = if params[:token].present?
      data = Rails.application.message_verifier("event-ticket").verified(params[:token], purpose: "check_in")
      return render_error("无效或已过期的票券") unless data && data["event_id"] == @event.id
      return check_in_team!(data["team_user_id"]) if data["team_user_id"]
      @event.participants.find_by(id: data["participant_id"], registered_at: data["registered_at"])
    else
      return check_in_team!(params[:user_id]) if team_member?(params[:user_id])
      @event.participants.find_by(user_id: params[:user_id])
    end
    return render_error("该用户尚未报名此活动") unless participant

    participant.with_lock do
      participant.refresh_payment_status!
      return render_error("报名未审核通过或已取消") unless participant.status == "attending"
      return render_error("票券尚未支付或已失效") unless participant.payment_status.nil? || participant.payment_status == "succeeded"
      participant.update!(checked_in_at: Time.current) unless participant.checked_in_at
    end
    render json: ParticipantBlueprint.render(participant, own: true)
  end

  # Only the holder can obtain their event-bound, short-lived credential.
  def ticket_pass
    if team_member?(current_user.id)
      token = Rails.application.message_verifier("event-ticket").generate(
        {"event_id" => @event.id, "team_user_id" => current_user.id}, purpose: "check_in", expires_in: 15.minutes)
      stamp = EventTeamCheckIn.find_by(event: @event, user: current_user)&.checked_in_at
      return render json: {participant: {status: "attending", checked_in_at: stamp, user: JSON.parse(UserBlueprint.render(current_user))},
                           token: token, expires_in: 900, tickets: [], team: true}
    end
    participant = @event.participants.find_by!(user: current_user)
    participant.refresh_payment_status!
    eligible = participant.status == "attending" && [nil, "succeeded"].include?(participant.payment_status)
    token = if eligible
      Rails.application.message_verifier("event-ticket").generate(
        { "event_id" => @event.id, "participant_id" => participant.id,
          "registered_at" => participant.registered_at&.iso8601(6) },
        purpose: "check_in", expires_in: 15.minutes)
    end
    render json: { participant: JSON.parse(ParticipantBlueprint.render(participant)),
                   token: token, expires_in: eligible ? 900 : 0,
                   tickets: JSON.parse(TicketItemBlueprint.render(participant.ticket_items.includes(:ticket), view: :order_detail)) }
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  private

  def team_member?(user_id)
    user = User.find_by(id: user_id)
    user && Event.team_for(user).exists?(id: @event.id) && @event.status.in?(%w[published closed])
  end

  def check_in_team!(user_id)
    return render_error("活动角色已移除或活动不可入场") unless team_member?(user_id)
    check_in = EventTeamCheckIn.create_or_find_by!(event: @event, user_id: user_id) do |record|
      record.checked_in_at = Time.current
    end
    render json: {status: "attending", checked_in_at: check_in.checked_in_at, team: true,
                  user: JSON.parse(UserBlueprint.render(User.find(user_id)))}
  end

  def withdraw_participant!(participant, status: "cancelled", require_refund: true)
    @event.with_lock do
      participant.with_lock do
        return if participant.status == status

        raise PaidRefundRequired if require_refund && RefundRequest.required_before_exit?(participant)
        release_orders!(participant)
        participant.reload
        if participant.status != status
          participant.transition!(status)
        end
        @event.reload.promote_waitlist!
        RegistrationReview.sync_form!(participant, "cancelled")
      end
    end
  end

  # Hands back the ticket units and coupon usage the withdrawing participant
  # was holding. The seat is not this method's business — it follows the
  # participant's own status (Participant#sync_event_seat!).
  #
  # A PAID order deliberately stays `succeeded` and keeps its money: an
  # attendee withdrawing is not a refund, and the event owner must still be
  # able to refund it afterwards from the order list — which is why the
  # participant link is left intact too.
  def release_orders!(participant)
    TicketItem.where(event_id: @event.id, participant_id: participant.id).each do |item|
      case item.status
      when "pending"
        item.cancel # marks cancelled and releases the hold
      when "succeeded"
        # Free/comped: nothing to refund, so retire the order outright. Paid:
        # leave it succeeded and refundable.
        item.transition!(:cancelled) if item.amount.to_i.zero?
        item.release_resources!
      end
    end
  end

  def set_event
    @event = Event.find(params[:event_id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # Only "attending" participants occupy a seat — mirrors
  # TicketsController#rsvp's venue-capacity check and the same
  # @event.participant_count counter it maintains, extended here to also
  # cover max_participant (rsvp has no ticket-quantity-independent event cap
  # to check; the free/direct-join path does).
  def capacity_error
    return "event is full" if RegistrationReview.capacity_full?(@event)

    if @event.venue&.capacity.to_i > 0 && @event.participant_count.to_i >= @event.venue.capacity
      return "exceed venue capacity"
    end

    nil
  end
end
