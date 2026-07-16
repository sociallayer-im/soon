class RecurringBlueprint < Blueprinter::Base
  identifier :id

  fields :start_time, :end_time, :interval, :event_count, :timezone, :created_at

  view :with_events do
    association :events, blueprint: EventBlueprint
  end
end
