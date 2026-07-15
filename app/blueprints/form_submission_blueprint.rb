class FormAnswerBlueprint < Blueprinter::Base
  identifier :id
  fields :form_field_id, :value
end

class FormSubmissionBlueprint < Blueprinter::Base
  identifier :id
  fields :form_id, :user_id, :status, :starred, :admin_note, :submitted_at

  association :form_answers, blueprint: FormAnswerBlueprint, name: :answers
  association :user, blueprint: UserBlueprint
end
