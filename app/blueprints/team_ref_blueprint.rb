# The shape a team takes when embedded on a membership row: enough to draw a
# badge and to filter by, nothing more.
#
# A separate blueprint rather than a view, following VenueRefBlueprint and
# TrackRefBlueprint — and load-bearing here: a group's roster is embedded whole
# on GroupBlueprint#detail (2407 memberships across the homepage's popup
# cities, per the note there), so every field costs that many times over.
class TeamRefBlueprint < Blueprinter::Base
  identifier :id
  fields :name, :slug, :color
end
