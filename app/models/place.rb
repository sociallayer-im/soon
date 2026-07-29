class Place < ApplicationRecord
  has_many :events, dependent: :nullify
  has_many :markers, dependent: :destroy

  validates :name, presence: true
  validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
  # Longitude spans ±180 (latitude's ±90 bound previously applied to both,
  # rejecting any place east of 90°E — e.g. Tokyo at 139°E).
  validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true

  # Name is intentionally NOT unique at the model/DB level: two genuinely
  # different real-world locations can share the same text name (a hotel
  # chain's "Patio" in two different cities, two venues both called
  # "Community Room"), and forcing a merge would corrupt data. Reuse on the
  # write path (PlacesController#create finding an exact existing name
  # before creating) is a soft, best-effort convenience, not an invariant.
  def self.find_or_create_by_name!(attrs)
    find_by(name: attrs[:name]) || create!(attrs)
  end
end
