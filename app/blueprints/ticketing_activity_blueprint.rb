# One entry in an order's history.
#
# `source` reaches the client on purpose: "backfill" means the row was
# reconstructed from timestamps after the fact rather than observed, and the UI
# should be able to say so rather than presenting a guess as a record.
class TicketingActivityBlueprint < Blueprinter::Base
  identifier :id

  fields :action, :from_status, :to_status, :source, :reason, :actor_user_id, :created_at

  # Free-form by design — what makes a row explainable differs per action
  # (a prepay id, a rejected callback's mismatch, a refund id).
  field :metadata
end
