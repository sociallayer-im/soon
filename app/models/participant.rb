class Participant < ApplicationRecord
  belongs_to :user
  belongs_to :event

  validates :status, presence: true, inclusion: { in: %w(attending declined maybe) }
  validates :user_id, uniqueness: { scope: :event_id, message: "can only participate once per event" }
end
