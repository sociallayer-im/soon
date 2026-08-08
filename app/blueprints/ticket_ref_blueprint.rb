# A ticket type as it appears embedded in an order — its label, nothing more.
#
# Separate from TicketBlueprint rather than a view of it, per the convention
# for embedded models (see VenueRefBlueprint, TrackRefBlueprint): an order list
# needs "which ticket type" and would otherwise carry quantity, badge gates and
# date restrictions for every row.
class TicketRefBlueprint < Blueprinter::Base
  identifier :id

  fields :title, :ticket_type
end
