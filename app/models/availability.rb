class Availability < ApplicationRecord
  belongs_to :item, polymorphic: true

  WEEKDAYS = %w(monday tuesday wednesday thursday friday saturday sunday).freeze

  validates :item_id, :item_type, presence: true
  validates :day_of_week, inclusion: { in: WEEKDAYS }, allow_nil: true
  validate :day_or_day_of_week_present

  # `intervals` is an array of ["HH:MM", "HH:MM"] pairs. An empty array is a
  # valid value meaning "closed" for that day/weekday, so intervals is NOT
  # validated for presence.

  private

  def day_or_day_of_week_present
    return if day.present? || day_of_week.present?
    errors.add(:base, "must set either a day (date override) or a day_of_week (weekly slot)")
  end
end
