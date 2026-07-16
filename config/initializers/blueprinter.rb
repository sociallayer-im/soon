# All API timestamps render as ISO 8601 UTC ("2026-07-16T06:09:56Z") — the
# default `to_s` ("2026-07-16 06:09:56 UTC") is not reliably parseable by
# JavaScript Date across engines.
Blueprinter.configure do |config|
  # Bare Date fields (start_date etc.) have no zone — plain iso8601 ("2026-09-01").
  config.datetime_format = ->(dt) { dt.respond_to?(:utc) ? dt.utc.iso8601 : dt&.iso8601 }
end
