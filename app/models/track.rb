class Track < ApplicationRecord
  belongs_to :group
  has_many :events, dependent: :nullify
  has_many :track_roles, dependent: :destroy
  has_many :users, through: :track_roles

  validates :name, presence: true, uniqueness: true
end
