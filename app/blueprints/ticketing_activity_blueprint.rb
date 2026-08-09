# One entry in an order's history.
#
# `source` reaches the client on purpose: "backfill" means the row was
# reconstructed from timestamps after the fact rather than observed, and the UI
# should be able to say so rather than presenting a guess as a record.
class TicketingActivityBlueprint < Blueprinter::Base
  identifier :id

  fields :action, :from_status, :to_status, :source, :reason, :actor_user_id, :created_at

  # WHO did it, resolved rather than left as an id, because an audit trail
  # nobody can read is not much of one. Null on purpose for anything a person
  # did not do — a callback, the sweeper — and that absence is itself
  # information: it says WeChat settled the refund, not a manager.
  #
  # Default view only: name and avatar, never the email. This is rendered to
  # every manager of the event, and the actor may be a different manager.
  association :actor, blueprint: UserBlueprint

  # Free-form by design — what makes a row explainable differs per action
  # (a prepay id, a rejected callback's mismatch, a refund id).
  field :metadata
end
