class FormAnswer < ApplicationRecord
  belongs_to :form_submission
  belongs_to :form_field
end
