class EventRole < ApplicationRecord
  belongs_to :event
  belongs_to :item, polymorphic: true

  validates :item_type, presence: true, inclusion: { in: %w(user group) }
  validates :role, presence: true, inclusion: { in: %w(member manager) }
  validates :item_id, uniqueness: { scope: [:event_id, :item_type], message: "can only have one role per item per event" }
end
