class Participant < ApplicationRecord
  belongs_to :user
  belongs_to :event
  belongs_to :voucher, optional: true
  belongs_to :badge, optional: true
  belongs_to :ticket, optional: true

  validates :status, presence: true, inclusion: { in: %w(attending declined maybe pending cancelled) }
  validates :user_id, uniqueness: { scope: :event_id, message: "can only participate once per event" }

  # "cancelled" is a soft delete (see ParticipantsController#destroy): the row
  # is kept for history and for a later refund to reach, but it must not show
  # up as an attendee anywhere, occupy capacity, or block a fresh RSVP —
  # which reuses the same row.
  scope :active, -> { where.not(status: "cancelled") }

  def cancelled? = status == "cancelled"
end
