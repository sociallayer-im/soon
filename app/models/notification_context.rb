# Request-local actor; reset after every request, including errors.
class NotificationContext < ActiveSupport::CurrentAttributes
  attribute :actor
end
