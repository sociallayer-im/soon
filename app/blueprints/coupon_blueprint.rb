class CouponBlueprint < Blueprinter::Base
  identifier :id

  fields :event_id, :selector_type, :label, :receiver_address, :discount_type, :discount,
         :applicable_ticket_ids, :ticket_item_ids, :expires_at, :max_allowed_usages, :order_usage_count

  view :with_code do
    field :code
  end
end
