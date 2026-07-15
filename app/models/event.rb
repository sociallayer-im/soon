class Event < ApplicationRecord
  belongs_to :group
  belongs_to :owner, class_name: "User"
  belongs_to :place, optional: true
  belongs_to :track, optional: true
  belongs_to :venue, optional: true
  belongs_to :recurring, optional: true
  has_many :participants, dependent: :destroy
  has_many :participant_users, through: :participants, source: :user
  has_many :event_roles, dependent: :destroy

  validates :title, presence: true
  validates :start_time, presence: true
  validates :end_time, presence: true
  validate :end_time_after_start_time

  private

  def end_time_after_start_time
    return unless start_time && end_time
    errors.add(:end_time, "must be after start time") if end_time <= start_time
  end
end
