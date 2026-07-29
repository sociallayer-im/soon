# Minimal venue reference for embedding on an event. Across the whole
# frontend, an event's venue is only ever read as `.id` (grouping in the
# schedule venue view, venue-picker prefill) and `.name` (location label) —
# never `about`/`amenities`/`image_urls`/nested `place`/etc, which belong to
# VenueBlueprint's full CRUD representation (venue management pages, embedded
# on GroupBlueprint#detail's `venues` list).
class VenueRefBlueprint < Blueprinter::Base
  identifier :id
  fields :name
end
