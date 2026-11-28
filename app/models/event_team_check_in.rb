# Team admission is independent of sold tickets, reservations and seat counts.
class EventTeamCheckIn < ApplicationRecord
  surf_visible_by(:event_id) { Event.select(:id) }

  belongs_to :event
  belongs_to :user
end
