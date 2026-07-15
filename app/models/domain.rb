class Domain < ApplicationRecord
  belongs_to :item, polymorphic: true

  validates :name, presence: true, uniqueness: true
  validates :item_type, :item_id, presence: true
end
