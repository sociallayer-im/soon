# Team admission is independent of sold tickets, reservations and seat counts.
class EventTeamCheckIn < ApplicationRecord
  belongs_to :event
  belongs_to :user
end
