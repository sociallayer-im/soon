class TicketItemBlueprint < Blueprinter::Base
  identifier :id

  fields :status, :ticket_id, :user_id, :event_id, :chain, :txhash, :amount, :discount_value,
         :discount_data, :participant_id, :ticket_type, :group_id, :auth_type, :tracks_allowed,
         :payment_method_id, :coupon_id, :sender_address, :selector_type, :selector_address,
         :original_price, :protocol, :created_at

  view :with_profile do
    association :user, blueprint: UserBlueprint
  end
end
