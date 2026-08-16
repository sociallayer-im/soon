class Api::V1::FormsController < Api::BaseController
  # The registration form is part of the public event page — an anonymous
  # visitor has to see what they'd be asked to fill in, and the event detail
  # loader fetches it with no token. Same 401-becomes-a-500 hazard as
  # recurring#show; #get_event_form authorizes the event itself instead.
  skip_before_action :authenticate!, only: :get_event_form
  before_action :authenticate_optional!, only: :get_event_form
  before_action :set_event

  # POST /api/v1/events/:event_id/form
  def save_event_form
    authorize @event, :update?

    form = @event.form || Form.new(created_by_id: current_user.id)
    form.title = params[:title].presence || "Application Form"
    form.published = true
    # Publishing the answers is a property of the FORM, so an event's
    # registration questions can opt in exactly like a standalone survey —
    # "who is coming and what did they say" is a thing organizers put on a
    # page. Absent from the params it keeps whatever it had, so an editor that
    # does not know about the flag cannot silently unpublish a wall of answers.
    if params.key?(:public_submissions)
      form.public_submissions = ActiveModel::Type::Boolean.new.cast(params[:public_submissions])
    end

    ActiveRecord::Base.transaction do
      form.save!
      @event.update_column(:form_id, form.id) unless @event.form_id == form.id
      @event.update_column(:require_approval, true) unless @event.require_approval

      FormBuilder.apply_fields!(form, params[:fields])
    end

    render json: FormBlueprint.render(form.reload, view: :extended)
  rescue FormBuilder::Error => e
    render_error(e.message)
  rescue ActiveRecord::RecordInvalid
    render_error("field label cannot be blank")
  end

  # DELETE /api/v1/events/:event_id/form
  def clear_event_form
    authorize @event, :update?
    @event.update_column(:form_id, nil)
    head :no_content
  end

  # GET /api/v1/events/:event_id/form
  def get_event_form
    # set_event uses a bare Event.find, so without this a draft or private
    # event's form would be readable by anyone who knew the event id.
    authorize @event, :show?
    render json: @event.form ? FormBlueprint.render(@event.form, view: :extended) : { form: nil }
  end

  # GET /api/v1/events/:event_id/form/submission
  def get_submission
    return render_not_found unless @event.form

    is_manager = @event.owner_id == current_user.id || group_admin_of?(@event.group)
    is_own = params[:user_id].to_s == current_user.id.to_s
    return render_error("not authorized", status: :forbidden) unless is_manager || is_own

    submission = @event.form.form_submissions.includes(:form_answers).find_by(user_id: params[:user_id])
    render json: submission ? FormSubmissionBlueprint.render(submission) : { submission: nil }
  end

  # GET /api/v1/events/:event_id/form/submissions
  def list_submissions
    return render_not_found unless @event.form

    is_manager = @event.owner_id == current_user.id || group_admin_of?(@event.group)
    return render_error("not authorized", status: :forbidden) unless is_manager

    submissions = @event.form.form_submissions.includes(:form_answers)
    render json: FormSubmissionBlueprint.render(submissions)
  end

  # GET /api/v1/events/:event_id/form/my_submission
  #
  # My own answers, without having to know my own user id. #get_submission
  # takes one and is the organizer's lookup; a person reading back what they
  # wrote should not have to resolve themselves first.
  def my_submission
    return render_not_found unless @event.form

    submission = @event.form.form_submissions.includes(:form_answers)
                       .find_by(user_id: current_user.id)
    render json: submission ? FormSubmissionBlueprint.render(submission) : { submission: nil }
  end

  # PATCH /api/v1/events/:event_id/form/submission
  #
  # Correct what I wrote on my application.
  #
  # This exists because there was no way to do it. The UI has offered an "edit
  # my application" dialog for a while, and it POSTed to participants#create —
  # which refuses anyone who is already participating, so every save came back
  # "User can only participate once per event" and the answers never changed.
  #
  # Only while the application is still pending: once the organizer has decided,
  # those answers are what they decided on, and editing them underneath would
  # leave an approval attached to something nobody read. Withdrawing and
  # applying again is the path after that, and it is honest about what it does.
  def update_submission
    return render_not_found unless @event.form

    participant = @event.participants.find_by(user_id: current_user.id)
    return render_error("you have not applied to this event") if participant.nil? || participant.cancelled?
    unless participant.status == "pending"
      return render_error("your application has already been reviewed and can no longer be edited")
    end

    answers = Array(params[:form_answers])
    missing = missing_required_fields(answers)
    return render_error("missing required form fields: #{missing.join(', ')}") if missing.any?

    submission = @event.form.form_submissions.find_or_initialize_by(user_id: current_user.id)
    ActiveRecord::Base.transaction do
      submission.status = "pending"
      submission.submitted_at = Time.current
      submission.save!
      FormBuilder.record_answers!(submission, answers, @event.form.form_fields.pluck(:id))
    end

    render json: FormSubmissionBlueprint.render(submission.reload)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  private

  def missing_required_fields(answers)
    @event.form.form_fields.where(required: true, for_admin: false).filter_map do |field|
      answer = answers.find { |a| a[:field_id].to_s == field.id.to_s }
      field.label if answer.nil? || answer[:value].blank?
    end
  end

  def set_event
    @event = Event.find(params[:event_id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def group_admin_of?(group)
    current_user.memberships.exists?(group: group, role: %w[manager owner])
  end
end
