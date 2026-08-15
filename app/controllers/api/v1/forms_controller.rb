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

    ActiveRecord::Base.transaction do
      form.save!
      @event.update_column(:form_id, form.id) unless @event.form_id == form.id
      @event.update_column(:require_approval, true) unless @event.require_approval

      FormBuilder.apply_fields!(form, params[:fields])
    end

    render json: FormBlueprint.render(form.reload, view: :extended)
  rescue FormBuilder::Error, ActiveRecord::RecordInvalid
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

  private

  def set_event
    @event = Event.find(params[:event_id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def group_admin_of?(group)
    current_user.memberships.exists?(group: group, role: %w[manager owner])
  end
end
