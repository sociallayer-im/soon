class Recurring < ApplicationRecord
  has_many :events, dependent: :destroy

  validates :start_time, :interval, presence: true
  validates :event_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :end_time_after_start_time

  private

  def end_time_after_start_time
    return unless start_time && end_time
    errors.add(:end_time, "must be after start time") if end_time <= start_time
  end
end
