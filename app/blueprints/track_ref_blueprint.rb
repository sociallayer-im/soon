# Minimal track reference for embedding on an event. Across the whole
# frontend, an event's track is only ever read as `.id` (track_id) and
# `.title` (label color/text) — never `description`/`image_url`/dates/the
# nested `group` (redundant — the event already carries its own group),
# which belong to TrackBlueprint's full CRUD representation (track
# management pages, embedded on GroupBlueprint#detail's `tracks` list).
class TrackRefBlueprint < Blueprinter::Base
  identifier :id
  fields :title
end
