class Recurring < ApplicationRecord
  INTERVALS = { "day" => :days, "week" => :weeks, "month" => :months }.freeze

  # nullify, not destroy: deleting a series must never cascade away the events
  # (and their participants/tickets). Cancelling a series soft-cancels the events.
  has_many :events, dependent: :nullify

  validates :start_time, :interval, presence: true
  validates :interval, inclusion: { in: INTERVALS.keys }
  validates :event_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :end_time_after_start_time

  private

  def end_time_after_start_time
    return unless start_time && end_time
    errors.add(:end_time, "must be after start time") if end_time <= start_time
  end
end
