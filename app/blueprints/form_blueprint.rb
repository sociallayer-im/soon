class FormFieldBlueprint < Blueprinter::Base
  identifier :id
  fields :label, :field_type, :required, :for_admin, :position, :options
end

class FormBlueprint < Blueprinter::Base
  identifier :id
  fields :title, :description, :published

  view :extended do
    association :form_fields, blueprint: FormFieldBlueprint, name: :fields
  end
end
