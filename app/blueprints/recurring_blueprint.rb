class RecurringBlueprint < Blueprinter::Base
  identifier :id

  fields :start_time, :end_time, :interval, :event_count, :timezone, :created_at

  view :with_events do
    # `visible_events` lets the caller hand in an already-scoped relation
    # (recurring#show filters by Event.visible_to) — without it the association
    # would render every occurrence, including drafts and private ones.
    association :events, blueprint: EventBlueprint do |recurring, options|
      options[:visible_events] || recurring.events
    end
  end
end
