# Applies a submitted field list to a form, in place.
#
# Extracted because two controllers now write form fields — the event
# registration form (FormsController#save_event_form) and standalone forms
# (StandaloneFormsController) — and a field type or validation added on one
# path but not the other is exactly the kind of drift that makes an uploaded
# answer render on one page and not the other.
#
# The list is authoritative: a field the caller no longer sends is deleted,
# **and so are the answers to it**.
#
# That is not a preference, it is the schema: `form_answers.form_field_id` is a
# foreign key with no cascade, so leaving the answers behind does not preserve
# them — it raises ForeignKeyViolation and fails the whole save. The previous
# code deleted only the fields and 500'd for any organizer who removed a
# question after the first application arrived. Orphaned answers would be
# useless anyway: nothing would be left to say what the question had been.
class FormBuilder
  Error = Class.new(StandardError)

  def self.apply_fields!(form, fields)
    fields = Array(fields)

    incoming_ids = fields.map { |f| f[:id].presence }.compact
    removed_ids = FormField.where(form_id: form.id).where.not(id: incoming_ids).pluck(:id)
    if removed_ids.any?
      FormAnswer.where(form_field_id: removed_ids).delete_all
      FormField.where(id: removed_ids).delete_all
    end

    fields.each_with_index do |field_params, index|
      raise Error, "field label cannot be blank" if field_params[:label].blank?

      attrs = attributes_for(field_params, index)
      # A multi_select answer is its options joined by MULTI_VALUE_SEPARATOR,
      # so an option containing that character could not be read back apart
      # from two options. Refused rather than silently rewritten: the author
      # can see the error and pick different wording, and mangling their text
      # behind their back is how a choice list ends up not matching the answers
      # already stored against it.
      if attrs[:options].any? { |o| o.to_s.include?(FormField::MULTI_VALUE_SEPARATOR) }
        raise Error, "an option cannot contain '#{FormField::MULTI_VALUE_SEPARATOR}'"
      end
      existing = field_params[:id].presence && FormField.find_by(id: field_params[:id], form_id: form.id)
      existing ? existing.update!(attrs) : form.form_fields.create!(attrs)
    end

    form
  end

  # Replaces a submission's answers with the ones supplied. Also shared by both
  # writers — the event application (participants#create) and standalone
  # submit — for the same reason as apply_fields!.
  #
  # Two rules the naive loop got wrong:
  #
  #   * An answer to a field that is not on this form is dropped. Nothing else
  #     would ever read it, and it is an unauthenticated write into a table
  #     otherwise.
  #   * At most ONE answer per field survives, the last one sent. There is no
  #     unique index on (submission, field), so a client repeating a field_id —
  #     by accident or on purpose — could write unbounded rows for a single
  #     question, all but one of which nothing would ever display.
  def self.record_answers!(submission, answers, field_ids)
    field_ids = field_ids.map(&:to_s).to_set
    by_field = {}
    Array(answers).each do |answer|
      field_id = answer[:field_id].to_s
      next unless field_ids.include?(field_id)
      by_field[field_id] = answer[:value]
    end

    FormAnswer.where(form_submission_id: submission.id).delete_all
    by_field.each do |field_id, value|
      FormAnswer.create!(form_submission_id: submission.id, form_field_id: field_id, value: value)
    end
  end

  def self.attributes_for(field_params, index)
    # An unrecognised type degrades to a plain text box rather than failing the
    # whole save: the organizer would otherwise lose an entire form's edits to
    # one stale field a newer client had written.
    field_type = field_params[:field_type].presence.to_s
    field_type = "text" unless FormField::FIELD_TYPES.include?(field_type)

    {
      label: field_params[:label],
      field_type: field_type,
      required: ActiveModel::Type::Boolean.new.cast(field_params[:required]) || false,
      for_admin: ActiveModel::Type::Boolean.new.cast(field_params[:for_admin]) || false,
      position: field_params[:position].presence || index,
      # Only the choice types carry options; keeping them on a text or upload
      # field would let a stale client resurrect a list after a type change.
      options: FormField::OPTION_TYPES.include?(field_type) ? Array(field_params[:options]) : []
    }
  end
end
