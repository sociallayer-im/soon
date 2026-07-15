class TrackRole < ApplicationRecord
  belongs_to :track
  belongs_to :user

  validates :role, presence: true, inclusion: { in: %w(member organizer admin) }
  validates :user_id, uniqueness: { scope: :track_id, message: "can only have one role per track" }
end
