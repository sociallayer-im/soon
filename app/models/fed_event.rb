# A remote event mirrored locally so our users can see and join it. The
# authoritative copy lives on the origin instance; this is a cache keyed by uri.
class FedEvent < ApplicationRecord
  belongs_to :fed_actor, optional: true
  has_many :fed_participations, dependent: :destroy

  validates :uri, presence: true, uniqueness: true

  scope :upcoming, -> { where("end_time IS NULL OR end_time >= ?", Time.current) }
  scope :listable, -> { where.not(status: "CANCELLED") }

  def cancelled? = status == "CANCELLED"

  # Where a Join for this event has to be delivered.
  def origin_inbox_url = fed_actor&.delivery_inbox_url

  def joinable?
    !cancelled? && %w[free restricted].include?(join_mode) &&
      (end_time.nil? || end_time > Time.current)
  end
end
