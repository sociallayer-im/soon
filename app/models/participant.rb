class Participant < ApplicationRecord
  belongs_to :user
  belongs_to :event
  belongs_to :voucher, optional: true
  belongs_to :badge, optional: true
  belongs_to :ticket, optional: true

  validates :status, presence: true, inclusion: { in: %w(attending declined maybe pending cancelled) }
  validates :user_id, uniqueness: { scope: :event_id, message: "can only participate once per event" }
end
