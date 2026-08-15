class FormField < ApplicationRecord
  belongs_to :form

  # `image` and `file` both store a URL in the answer's `value`, exactly like
  # `text` does — the upload happens first (POST /upload/image or
  # /upload/file), and the form only ever carries the resulting
  # datastore.sola.day link. Nothing about a submission is binary, so no
  # attachment table is involved.
  #
  # They are two types rather than one so the applicant gets the right control
  # (a camera-roll picker and a thumbnail preview vs. a document picker) and
  # the organizer's submission list knows whether it can render the answer
  # inline.
  FIELD_TYPES = %w[text select image file].freeze

  validates :field_type, inclusion: { in: FIELD_TYPES }

  def upload? = %w[image file].include?(field_type)
end
