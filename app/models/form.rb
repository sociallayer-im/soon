class Form < ApplicationRecord
  # Declared BEFORE form_fields on purpose: dependent: :destroy runs in
  # declaration order, and form_answers has a no-cascade foreign key on
  # form_field_id. Destroying the fields first left the answers pointing at
  # rows being deleted and raised ForeignKeyViolation — so deleting a form that
  # anyone had answered failed outright. Submissions take their answers with
  # them, which clears the way for the fields.
  has_many :form_submissions, dependent: :destroy
  has_many :form_fields, -> { order(:position) }, dependent: :destroy

  before_create :set_slug

  private

  def set_slug
    self.slug ||= id
  end
end
