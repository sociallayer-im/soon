class TicketBlueprint < Blueprinter::Base
  identifier :id

  fields :title, :content, :event_id, :check_badge_class_id, :check_group_ids, :quantity, :end_time,
         :need_approval, :status, :ticket_type, :group_id, :start_date, :end_date,
         :days_allowed, :tracks_allowed, :created_at, :membership_duration_days

  view :extended do
    association :payment_methods, blueprint: PaymentMethodBlueprint
  end
end
