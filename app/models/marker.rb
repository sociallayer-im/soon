class Marker < ApplicationRecord
  belongs_to :place
  belongs_to :group
  belongs_to :owner, class_name: "User", foreign_key: "owner_id"

  validates :title, presence: true
  validates :place_id, :group_id, :owner_id, presence: true
end
