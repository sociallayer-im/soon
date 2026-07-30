class Api::V1::ParticipantsController < Api::BaseController
  before_action :set_event

  # GET /api/v1/events/:event_id/participants
  #
  # Withdrawn participants are soft-deleted (status "cancelled") and must not
  # appear in the attendee list — before the soft delete they were removed
  # outright, so nothing downstream expects to see them.
  def index
    render_collection @event.participants.active.includes(:user), blueprint: ParticipantBlueprint
  end

  # POST /api/v1/events/:event_id/participants
  def create
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
    # event_id) is unique, so a second insert would fail. Anything else that
    # already exists is still a duplicate join and rejected as before.
    if existing && !existing.cancelled?
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

      if @event.form_id && params[:form_answers].present?
        valid_field_ids = FormField.where(form_id: @event.form_id).pluck(:id)
        submission = FormSubmission.find_or_initialize_by(form_id: @event.form_id, user_id: current_user.id)
        submission.status = "pending"
        submission.submitted_at = Time.current
        submission.save!
        FormAnswer.where(form_submission_id: submission.id).delete_all
        Array(params[:form_answers]).each do |answer|
          next unless valid_field_ids.include?(answer[:field_id].to_s)
          FormAnswer.create!(form_submission_id: submission.id, form_field_id: answer[:field_id], value: answer[:value])
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
    was_attending = participant.status == "attending"
    will_attend = new_status == "attending"
    if will_attend && !was_attending && (err = capacity_error)
      return render_error(err)
    end

    if participant.update(status: new_status)
      @event.increment!(:participant_count) if will_attend && !was_attending
      @event.decrement!(:participant_count) if was_attending && !will_attend && @event.participant_count.to_i > 0
      render json: ParticipantBlueprint.render(participant)
    else
      render_error(participant.errors.full_messages.join(", "))
    end
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

    was_attending = participant.status == "attending"
    released = false
    ActiveRecord::Base.transaction do
      released = release_orders!(participant)
      participant.update!(status: "cancelled")
    end
    # release_resources! already gave the seat back (and the count with it) —
    # decrementing again here would double-count.
    @event.decrement!(:participant_count) if was_attending && !released && @event.participant_count.to_i > 0
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

    participant.update!(status: "attending")
    @event.increment!(:participant_count)
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

    participant.update!(status: "declined")
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

  # Hands back what the withdrawing participant was holding. Returns true if
  # inventory was released, so the caller doesn't decrement participant_count
  # twice (release_resources! already covers it).
  #
  # A PAID order deliberately stays `succeeded` and keeps its money: an
  # attendee withdrawing is not a refund, and the event owner must still be
  # able to refund it afterwards from the order list — which is why the
  # participant link is left intact too.
  def release_orders!(participant)
    released = false
    TicketItem.where(event_id: @event.id, participant_id: participant.id).each do |item|
      case item.status
      when "pending"
        item.cancel # marks cancelled and releases the hold
        released = true
      when "succeeded"
        # Free/comped: nothing to refund, so retire the order outright. Paid:
        # leave it succeeded and refundable.
        item.transition!(:cancelled) if item.amount.to_i.zero?
        item.release_resources!
        released = true
      end
    end
    released
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
