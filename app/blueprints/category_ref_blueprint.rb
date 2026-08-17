# The shape a category takes when embedded on a topic: enough to label and
# link it, nothing more. A separate blueprint rather than a view on
# CategoryBlueprint, following VenueRefBlueprint/TrackRefBlueprint.
class CategoryRefBlueprint < Blueprinter::Base
  identifier :id
  fields :name, :slug, :visibility
end
