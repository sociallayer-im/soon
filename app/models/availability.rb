class Availability < ApplicationRecord
  belongs_to :item, polymorphic: true

  validates :item_id, :item_type, presence: true
  validates :intervals, presence: true
end
