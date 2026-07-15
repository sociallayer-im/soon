class Venue < ApplicationRecord
  belongs_to :group
  belongs_to :owner, class_name: "User"
  belongs_to :place, optional: true
  has_many :events, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :capacity, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
end
