class Place < ApplicationRecord
  has_many :events, dependent: :nullify
  has_many :markers, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
  # Longitude spans ±180 (latitude's ±90 bound previously applied to both,
  # rejecting any place east of 90°E — e.g. Tokyo at 139°E).
  validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true

  # Places are shared/deduped by name: creating an existing place returns the
  # existing record (the frontend resolves every location to a place_id first).
  def self.find_or_create_by_name!(attrs)
    find_by(name: attrs[:name]) || create!(attrs)
  end
end
