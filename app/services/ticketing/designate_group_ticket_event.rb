module Ticketing
  # Makes an event THE group's ticket event: the one whose tickets grant
  # membership. groups.group_ticket_event_id is the single source of truth —
  # Ticket#inherit_group_ticket_type, add_group_ticket_item and GroupInvite all
  # read it, and nothing is denormalised onto the event. It was not settable
  # through the API before, so the group-ticket feature could not be turned on
  # at all.
  #
  # At most one per group: a second one would split the grants between two
  # containers, and add_group_ticket_item only ever reads one.
  class DesignateGroupTicketEvent
    Result = Struct.new(:error, keyword_init: true) do
      def ok? = error.nil?
    end

    def self.call(event:, group:, designate:)
      current = group.group_ticket_event_id

      if designate
        return failure("this group already has a group ticket event") if current.present? && current != event.id

        group.update!(group_ticket_event_id: event.id)
      else
        # Only ever clears THIS event's designation.
        group.update!(group_ticket_event_id: nil) if current == event.id
      end
      Result.new
    end

    def self.failure(message) = Result.new(error: message)
  end
end
