class Campaign < ApplicationRecord
  belongs_to :owner, class_name: "User"
  belongs_to :group, optional: true
  has_many :reviews, dependent: :destroy

  STATUSES = %w[draft in_review changes_requested published].freeze
  WRITABLE_EVENT_STATUSES = %w[published pending].freeze

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :round, numericality: { only_integer: true, greater_than: 0 }
  validate :event_ids_are_writable

  before_validation :dedupe_event_ids

  # Stored ids stay put. A public read keeps only events that still exist and
  # are published, in the stored order.
  def published_event_ids
    live = Event.where(id: event_ids, status: "published").pluck(:id)
    Array(event_ids).select { |id| live.include?(id) }
  end

  def event_statuses
    found = Event.where(id: event_ids).pluck(:id, :status).to_h
    Array(event_ids).map { |id| { "id" => id, "status" => found[id] } }
  end

  private

  def dedupe_event_ids
    self.event_ids = Array(event_ids).map(&:to_s).uniq
  end

  def event_ids_are_writable
    ids = Array(event_ids)
    return if ids.empty?

    found = Event.where(id: ids).pluck(:id, :status).to_h
    ids.each do |id|
      status = found[id]
      if status.nil?
        errors.add(:event_ids, "includes an unknown event")
      elsif !WRITABLE_EVENT_STATUSES.include?(status)
        errors.add(:event_ids, "includes an event that is not published or pending")
      end
    end
  end
end
