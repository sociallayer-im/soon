# A local user's participation in a remote event. `status` starts pending —
# only the origin instance can approve, and it says so with an Accept
# (Mobilizon types/events.ex:197-248 refuses to Accept a join for an event it
# does not own).
class FedParticipation < ApplicationRecord
  STATUSES = %w[pending attending rejected cancelled].freeze

  belongs_to :user
  belongs_to :fed_event

  validates :status, inclusion: {in: STATUSES}
  validates :uri, presence: true, uniqueness: true

  scope :active, -> { where(status: %w[pending attending]) }
end
