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
  # `textarea`, `date` and `url` are all stored as text, exactly like `text`:
  # they differ only in the control the respondent gets and how the answer is
  # rendered back. Nothing here parses or validates the value, deliberately —
  # a date whose format the browser and the server disagree about would fail a
  # submission the respondent has no way to fix.
  FIELD_TYPES = %w[text textarea select multi_select date url image file].freeze

  # `select` and `multi_select` are the two that carry `options`. A
  # multi_select answer is the chosen options joined by this separator, in one
  # `value` like every other answer — there is no answer-per-choice row, so
  # nothing about the schema changes and an existing single-select answer is
  # already a valid multi_select answer of one.
  MULTI_VALUE_SEPARATOR = "|".freeze
  OPTION_TYPES = %w[select multi_select].freeze

  validates :field_type, inclusion: { in: FIELD_TYPES }

  def upload? = %w[image file].include?(field_type)
end
