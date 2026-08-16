# Forms that belong to nobody but their author.
#
# A Form has never actually depended on an Event — `events.form_id` points AT a
# form, not the other way round — so this controller adds no new model, only
# the endpoints for using one on its own: a survey, a call for proposals, a
# sign-up sheet with no event behind it.
#
# The one rule worth stating: a person has at most ONE submission per form
# (unique index on form_id+user_id), and re-submitting EDITS it rather than
# adding a second. That is what "重新填写" means here — the organizer sees one
# answer per person, always the latest, and the person can go back and fix a
# typo instead of filing a duplicate.
class Api::V1::StandaloneFormsController < Api::BaseController
  # Filling in a form starts by reading it, and a form is meant to be shared as
  # a link — so an anonymous visitor must be able to see what is being asked.
  # Only *published* forms are readable that way; a draft is the author's.
  # `submissions` joins `show` in being anonymously readable, but only for a
  # form whose author turned that on — see #submissions.
  skip_before_action :authenticate!, only: %i[show submissions]
  before_action :authenticate_optional!, only: %i[show submissions]
  before_action :set_form, only: %i[show update destroy submissions submit my_submission]

  # GET /api/v1/forms — the forms I created.
  #
  # Event registration forms are included rather than filtered out: they are
  # mine too, and a hub that silently omitted half of them would be worse than
  # useless. Each carries the event_id that owns it, so the page can send the
  # organizer to the event's own editor instead of a rival one.
  def index
    scope = Form.where(created_by_id: current_user.id)
                .includes(:form_fields)
                .order(created_at: :desc)
    # The counts are grouped queries over the WHOLE scope rather than per row,
    # so rendering a page of 20 costs three queries instead of forty-one.
    ids = scope.reorder(nil).select(:id)
    render_collection scope,
      blueprint: FormBlueprint,
      view: :with_counts,
      submission_counts: FormSubmission.where(form_id: ids).group(:form_id).count,
      event_ids: Event.where(form_id: ids).pluck(:form_id, :id).to_h
  end

  # GET /api/v1/forms/submissions — the forms I filled in.
  #
  # Deliberately not "my forms with a submission attached": the point of the
  # page is the answer, and the form is context for it, so the submission is
  # the row.
  def my_submissions
    render_collection FormSubmission.where(user_id: current_user.id)
                                    .includes(:user, :form_answers, form: :form_fields)
                                    .order(submitted_at: :desc),
      blueprint: FormSubmissionBlueprint, view: :with_form
  end

  # POST /api/v1/forms
  def create
    form = Form.new(created_by_id: current_user.id)
    apply_form_attributes(form)

    ActiveRecord::Base.transaction do
      form.save!
      FormBuilder.apply_fields!(form, params[:fields])
    end
    render json: FormBlueprint.render(form.reload, view: :extended, can_edit: true), status: :created
  rescue FormBuilder::Error => e
    render_error(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # GET /api/v1/forms/:slug
  def show
    # A draft is not published yet: it exists for its author to keep working
    # on, and a shared link to one must not leak the questions early.
    return render_not_found unless @form.published || manages_form?
    render json: FormBlueprint.render(@form, view: :extended, can_edit: manages_form?)
  end

  # PATCH /api/v1/forms/:slug
  def update
    return render_forbidden unless manages_form?

    apply_form_attributes(@form)
    ActiveRecord::Base.transaction do
      @form.save!
      FormBuilder.apply_fields!(@form, params[:fields]) if params.key?(:fields)
    end
    render json: FormBlueprint.render(@form.reload, view: :extended, can_edit: true)
  rescue FormBuilder::Error => e
    render_error(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # DELETE /api/v1/forms/:slug
  #
  # Refused while an event still points at the form: deleting it would take
  # the event's registration questions and every applicant's answers with it,
  # which is not what "delete this form of mine" is asking for.
  def destroy
    return render_forbidden unless manages_form?
    if Event.exists?(form_id: @form.id)
      return render_error("this form is in use by an event; detach it there first")
    end

    @form.destroy
    head :no_content
  end

  # GET /api/v1/forms/:slug/submissions — everything people answered. Author only.
  # GET /api/v1/forms/:slug/submissions
  #
  # The author always; everyone else only when the form is published AND its
  # author set public_submissions — a wall of answers, a directory, a list of
  # who is coming. That flag belongs to the FORM, event-attached or not: an
  # event's registration answers are as publishable as a survey's if whoever
  # wrote the questions says so.
  #
  # What "everyone" sees is the same UserBlueprint the attendee list uses —
  # name, handle, avatar. Never email or phone, which is why this can be
  # opened up at all.
  #
  # Paginated, unlike the event-scoped list it grew out of: a form shared as a
  # public link has no upper bound on responses, and rendering every one of
  # them with its user and answers in a single document is a request that gets
  # slower the more successful the form is.
  def submissions
    return render_forbidden unless manages_form? || publicly_readable?
    render_collection @form.form_submissions.includes(:form_answers, :user).order(submitted_at: :desc),
      blueprint: FormSubmissionBlueprint
  end

  # GET /api/v1/forms/:slug/my_submission — what I answered, for prefilling the
  # form when I come back to change it. `{submission: null}` when I never have.
  def my_submission
    submission = @form.form_submissions.includes(:form_answers)
                      .find_by(user_id: current_user.id)
    render json: submission ? FormSubmissionBlueprint.render(submission) : { submission: nil }
  end

  # POST /api/v1/forms/:slug/submissions — fill it in, or change what I filled in.
  def submit
    return render_error("this form is not accepting responses") unless @form.published
    # An event's registration questions are answered by JOINING the event
    # (participants#create), which creates the participant this endpoint knows
    # nothing about. Without this, the form's slug — which the public event
    # page now carries — is a second front door that files an application the
    # organizer's applicant list never shows.
    if Event.exists?(form_id: @form.id)
      return render_error("this form belongs to an event; register there instead")
    end

    answers = Array(params[:answers])
    missing = missing_required_fields(answers)
    return render_error("missing required fields: #{missing.join(', ')}") if missing.any?

    submission = @form.form_submissions.find_or_initialize_by(user_id: current_user.id)
    was_edit = submission.persisted?

    ActiveRecord::Base.transaction do
      # An edited submission goes back to "pending". Anything else would let
      # someone alter the answers behind a decision the organizer has already
      # made — approved on one set of answers, holding another.
      submission.status = "pending" if submission.new_record? || submission.status != "pending"
      submission.submitted_at = Time.current
      submission.save!

      FormBuilder.record_answers!(submission, answers, @form.form_fields.pluck(:id))
    end

    render json: FormSubmissionBlueprint.render(submission.reload),
           status: was_edit ? :ok : :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  private

  def set_form
    @form = Form.find_by(slug: params[:slug]) || Form.find_by(id: params[:slug])
    render_not_found unless @form
  end

  # An unpublished form's answers stay private whatever the flag says: a draft
  # is not something anyone but its author is meant to reach, and publishing
  # the responses to one would be a stranger surprise than the flag promises.
  def publicly_readable?
    @form.published && @form.public_submissions
  end

  def apply_form_attributes(form)
    form.title = params[:title] if params.key?(:title) || form.new_record?
    form.title = "Untitled Form" if form.title.blank?
    form.description = params[:description] if params.key?(:description)
    form.submission_message = params[:submission_message] if params.key?(:submission_message)
    form.published = ActiveModel::Type::Boolean.new.cast(params[:published]) if params.key?(:published)
    if params.key?(:public_submissions)
      form.public_submissions = ActiveModel::Type::Boolean.new.cast(params[:public_submissions])
    end
  end

  # The author, or anyone who can edit the event this form is attached to —
  # an event's registration form is managed from the event, and its group's
  # managers are the people who manage it.
  def manages_form?
    return false unless current_user
    return true if @form.created_by_id == current_user.id

    event = Event.find_by(form_id: @form.id)
    event.present? && EventPolicy.new(current_user, event).update?
  end

  def missing_required_fields(answers)
    @form.form_fields.where(required: true, for_admin: false).filter_map do |field|
      answer = answers.find { |a| a[:field_id].to_s == field.id.to_s }
      field.label if answer.nil? || answer[:value].blank?
    end
  end

  def render_forbidden
    render json: { error: "Forbidden" }, status: :forbidden
  end
end
