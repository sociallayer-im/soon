class Api::V1::ParticipantsController < Api::BaseController
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
    render_collection @event.participants.active.includes(:user), blueprint: ParticipantBlueprint
  end

  # POST /api/v1/events/:event_id/participants
  def create
    authorize @event, :join?

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

    is_manager = current_user.memberships.exists?(group: @event.group, role: %w[manager owner])
    status = params.dig(:participant, :status) || "attending"
    status = "pending" if (@event.require_approval || @event.form_id.present?) && !is_manager

    existing = @event.participants.find_by(user_id: current_user.id)
    # Re-joining after withdrawing REUSES the soft-deleted row — (user_id,
    # event_id) is unique, so a second insert would fail. A rejected applicant
    # may re-apply for the same reason a withdrawn one may re-join: neither
    # holds a seat, and "declined" is not meant to be a permanent ban — the
    # transition table has allowed declined → pending/attending all along, it
    # was only this guard that made it unreachable. Anything else that already
    # exists is still a duplicate join and rejected as before.
    if existing && !existing.cancelled? && existing.status != "declined"
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
    if status == "attending" && (err = capacity_error)
      return render_error(err)
    end

    participant.assign_attributes(status: status, registered_at: Time.current)

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
          submission.status = "pending"
          submission.save!
          if params[:form_answers].present?
            FormBuilder.record_answers!(submission, params[:form_answers],
                                        FormField.where(form_id: @event.form_id).pluck(:id))
          end
        end
      end
    end

    render json: ParticipantBlueprint.render(participant), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # PATCH /api/v1/events/:event_id/participants/:id
  def update
    participant = @event.participants.find(params[:id])
    unless participant.user_id == current_user.id
      return render json: { error: "Forbidden" }, status: :forbidden
    end

    new_status = params.dig(:participant, :status)
    was_seated = participant.seated?
    will_be_seated = Participant::SEATED.include?(new_status)
    if will_be_seated && !was_seated && (err = capacity_error)
      return render_error(err)
    end

    # transition! moves participant_count itself — the seat follows the status.
    participant.transition!(new_status)
    render json: ParticipantBlueprint.render(participant)
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
    unless participant.user_id == current_user.id
      return render json: { error: "Forbidden" }, status: :forbidden
    end
    return head :no_content if participant.status == "cancelled" # idempotent

    ActiveRecord::Base.transaction do
      release_orders!(participant)
      # Cancelling the last live order already withdraws the participant
      # (TicketItem#settle_participant!), so only transition if it didn't.
      # Either way the seat is given back exactly once, by whichever
      # transition! actually ran.
      participant.reload
      participant.transition!(:cancelled) unless participant.cancelled?
    end
    head :no_content
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
    return render_error("participant is not pending") unless participant.status == "pending"

    participant.transition!(:attending)
    sync_form_submission!(participant, "approved")
    EventMailer.participant_approved(participant_id: participant.id).deliver_later
    render json: ParticipantBlueprint.render(participant)
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # POST /api/v1/events/:event_id/participants/:id/reject
  #
  # Event owner or group admin/owner declines a pending applicant.
  def reject
    authorize @event, :update?
    participant = @event.participants.find(params[:id])
    return render_error("participant is not pending") unless participant.status == "pending"

    participant.transition!(:declined)
    sync_form_submission!(participant, "rejected")
    EventMailer.participant_rejected(participant_id: participant.id).deliver_later
    render json: ParticipantBlueprint.render(participant)
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
    # .active — someone who withdrew is not at the door.
    participant = @event.participants.active.find_by(user_id: params[:user_id])
    return render_error("user is not a participant of this event") unless participant

    participant.update!(checked_in_at: Time.current)
    render json: ParticipantBlueprint.render(participant)
  end

  private

  # The approval decision lives on the participant; the application form's
  # submission carried its own status that nobody ever advanced, so a decided
  # applicant still read as "pending" in the submissions list.
  def sync_form_submission!(participant, status)
    return unless @event.form_id

    FormSubmission.where(form_id: @event.form_id, user_id: participant.user_id)
                  .update_all(status: status, updated_at: Time.current)
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
    return "event is full" if @event.max_participant && @event.participant_count.to_i >= @event.max_participant

    if @event.venue&.capacity.to_i > 0 && @event.participant_count.to_i >= @event.venue.capacity
      return "exceed venue capacity"
    end

    nil
  end
end
