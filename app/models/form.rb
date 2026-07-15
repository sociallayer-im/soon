class Form < ApplicationRecord
  has_many :form_fields, -> { order(:position) }, dependent: :destroy
  has_many :form_submissions, dependent: :destroy

  before_create :set_slug

  private

  def set_slug
    self.slug ||= id
  end
end
