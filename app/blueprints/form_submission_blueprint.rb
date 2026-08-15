class FormAnswerBlueprint < Blueprinter::Base
  identifier :id
  fields :form_field_id, :value
end

class FormSubmissionBlueprint < Blueprinter::Base
  identifier :id
  fields :form_id, :user_id, :status, :starred, :admin_note, :submitted_at, :updated_at

  association :form_answers, blueprint: FormAnswerBlueprint, name: :answers
  association :user, blueprint: UserBlueprint

  # For "forms I filled in": the answer is the row, and the form is the context
  # that makes it readable — without the field list, a list of answers is a
  # list of values with nothing to label them.
  view :with_form do
    association :form, blueprint: FormBlueprint, view: :extended
  end
end
