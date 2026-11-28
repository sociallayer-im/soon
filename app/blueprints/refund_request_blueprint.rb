class RefundRequestBlueprint < Blueprinter::Base
  identifier :id
  fields :status, :reason, :review_reason, :reviewed_at, :created_at, :updated_at
  field :can_review do |request, options|
    request.status == "requested" && TicketItemPolicy.new(options[:viewer], request.ticket_item).refund?
  end
end
