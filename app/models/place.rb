class Place < ApplicationRecord
  has_many :events, dependent: :nullify
  has_many :markers, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :latitude, :longitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
end
