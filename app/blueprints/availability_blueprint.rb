class AvailabilityBlueprint < Blueprinter::Base
  identifier :id

  fields :day, :day_of_week, :intervals, :role_required
end
