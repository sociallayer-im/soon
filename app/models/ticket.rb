class Ticket < ApplicationRecord
  belongs_to :event
  belongs_to :group, optional: true
  has_many :ticket_items, dependent: :delete_all
  has_many :payment_methods, as: :item, dependent: :delete_all

  accepts_nested_attributes_for :payment_methods, allow_destroy: true

  validates :status, inclusion: { in: %w(normal nosale hidden inactive) }
  validates :ticket_type, inclusion: { in: %w(event group membership_card) }
  validates :membership_duration_days, numericality: { greater_than: 0 },
    if: -> { ticket_type == "membership_card" }

  # A group/membership_card ticket's group_id is client-suppliable (ticket_params
  # permits it directly), but ticket create/update only authorizes against the
  # EVENT (owner/group_admin/co-host) — never against the group_id itself. Without
  # this, anyone who can edit some unrelated event could point group_id at a group
  # they have no role in, and a successful purchase would grant real membership
  # there via TicketItem#confirm_payment!. Tying it to the event's own group closes
  # that: the same authorization check that gates the ticket now transitively gates
  # which group it can ever grant into.
  validate :group_matches_event_group, if: -> { ticket_type.in?(%w[group membership_card]) }

  # Must run before the validation above, not after (before_save fires too
  # late — validations have already run by then), so a ticket on the group's
  # designated ticket event still gets its group_id auto-filled before
  # group_matches_event_group checks it.
  before_validation :inherit_group_ticket_type

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

  # Tickets on the group's designated ticket event grant membership, so they
  # default to group tickets whatever the caller asked for. Keyed off
  # groups.group_ticket_event_id — the previous check (event.kind ==
  # "group_ticket") never fired, because nothing ever set that kind.
  #
  # membership_card is exempt from the override: it's an explicit choice on
  # this same event (a 30-day renewable membership instead of a permanent
  # one), not something that should be silently downgraded to "group".
  def inherit_group_ticket_type
    return unless event&.group_ticket_event?
    self.ticket_type = "group" unless ticket_type == "membership_card"
    self.group_id = event.group_id
  end

  def group_matches_event_group
    return if group_id == event&.group_id
    errors.add(:group_id, "must be the event's own group for a #{ticket_type} ticket")
  end
end
