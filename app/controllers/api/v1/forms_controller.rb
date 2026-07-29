class Api::V1::FormsController < Api::BaseController
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

      incoming_ids = Array(params[:fields]).map { |f| f[:id].presence }.compact
      FormField.where(form_id: form.id).where.not(id: incoming_ids).delete_all

      Array(params[:fields]).each_with_index do |field_params, index|
        raise ActiveRecord::RecordInvalid.new(form) if field_params[:label].blank?

        field_type = field_params[:field_type].presence || "text"
        options = field_type == "select" ? Array(field_params[:options]) : []
        attrs = {
          label: field_params[:label],
          field_type: field_type,
          required: ActiveModel::Type::Boolean.new.cast(field_params[:required]) || false,
          for_admin: ActiveModel::Type::Boolean.new.cast(field_params[:for_admin]) || false,
          position: field_params[:position].presence || index,
          options: options
        }
        if field_params[:id].present?
          field = FormField.find_by(id: field_params[:id], form_id: form.id)
          field ? field.update!(attrs) : form.form_fields.create!(attrs)
        else
          form.form_fields.create!(attrs)
        end
      end
    end

    render json: FormBlueprint.render(form.reload, view: :extended)
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
