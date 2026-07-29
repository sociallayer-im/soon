class Api::V1::ParticipantsController < Api::BaseController
  before_action :set_event

  # GET /api/v1/events/:event_id/participants
  def index
    render_collection @event.participants.includes(:user), blueprint: ParticipantBlueprint
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

    # Only a status that counts toward capacity needs the check — a "pending"
    # join (awaiting approval) doesn't occupy a seat yet, matching sails/'s
    # "only count confirmed attendees; pending waits until approval".
    if status == "attending" && (err = capacity_error)
      return render_error(err)
    end

    participant = @event.participants.new(user: current_user, status: status)

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
  def destroy
    participant = @event.participants.find(params[:id])
    unless participant.user_id == current_user.id
      return render json: { error: "Forbidden" }, status: :forbidden
    end
    was_attending = participant.status == "attending"
    participant.destroy
    @event.decrement!(:participant_count) if was_attending && @event.participant_count.to_i > 0
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
  # Manager scans an attendee at the door: stamps register_time on their
  # participant record. Idempotent — re-checking-in just re-stamps.
  def check_in
    authorize @event, :update?
    participant = @event.participants.find_by(user_id: params[:user_id])
    return render_error("user is not a participant of this event") unless participant

    participant.update!(register_time: Time.current)
    render json: ParticipantBlueprint.render(participant)
  end

  private

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
