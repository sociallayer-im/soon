class Ticket < ApplicationRecord
  belongs_to :event
  belongs_to :group, optional: true
  has_many :ticket_items, dependent: :delete_all
  has_many :payment_methods, as: :item, dependent: :delete_all

  accepts_nested_attributes_for :payment_methods, allow_destroy: true

  validates :status, inclusion: { in: %w(normal nosale hidden inactive) }
  validates :ticket_type, inclusion: { in: %w(event group) }

  before_save :inherit_group_ticket_type

  # Atomically claims one unit of quantity. Returns true if reserved (or unlimited),
  # false if sold out — never lets quantity go negative under concurrent callers.
  def reserve!
    return true if quantity.nil?

    with_lock do
      return false if quantity <= 0
      decrement!(:quantity)
    end
    true
  end

  # Inverse of reserve! — releases one unit back (cancel/timeout).
  def release!
    return if quantity.nil?

    with_lock { increment!(:quantity) }
  end

  private

  def inherit_group_ticket_type
    return unless event&.kind == "group_ticket"
    self.ticket_type = "group"
    self.group_id = event.group_id
  end
end
