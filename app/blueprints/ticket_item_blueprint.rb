class TicketItemBlueprint < Blueprinter::Base
  identifier :id

  fields :status, :ticket_id, :user_id, :event_id, :chain, :txhash, :amount, :discount_value,
         :discount_data, :participant_id, :ticket_type, :group_id, :auth_type, :tracks_allowed,
         :payment_method_id, :coupon_id, :sender_address, :selector_type, :selector_address,
         :original_price, :protocol, :created_at,
         # As charged, not as currently configured — an order keeps the
         # currency it was taken in. nil on crypto orders.
         :currency

  view :with_profile do
    association :user, blueprint: UserBlueprint
  end

  # The organizer's order list: enough to reconstruct what happened to an
  # order without an audit table.
  #
  # There is no transitions log — status is a single current value — so the
  # history has to come from the timestamps that each transition writes plus
  # the refund rows, which are the only part of an order's life that keeps its
  # own record. That covers what an organizer actually needs to explain: when
  # it was ordered, when the money landed, and every refund with its outcome.
  # A real audit table (design/PAYMENTS_PLAN.md §3.6) would additionally
  # capture expiry and cancellation reasons; this does not.
  view :order_detail do
    include_view :with_profile

    fields :payment_provider, :provider_ref, :paid_at, :released_at, :reserved_until, :updated_at

    association :ticket, blueprint: TicketRefBlueprint

    # Ordered oldest-first so the client can render them as a timeline without
    # having to know to sort.
    association :refunds, blueprint: RefundBlueprint do |item, _options|
      item.refunds.order(:created_at)
    end

    # The recorded history. Supersedes deriving one from the timestamps above,
    # which could not see a retry, a rejected callback, or the difference
    # between a voluntary refund and a lost dispute.
    association :activities, blueprint: TicketingActivityBlueprint do |item, _options|
      item.ticketing_activities.oldest_first
    end
  end
end
