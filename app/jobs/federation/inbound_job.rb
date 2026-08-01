module Federation
  # Runs the business half of an inbound activity. Signature verification
  # already happened in the request; the inbox 202s fast and defers here so
  # remote senders never time out on our processing.
  class InboundJob < ApplicationJob
    queue_as :federation

    def perform(fed_actor_id, activity)
      fed_actor = FedActor.find_by(id: fed_actor_id)
      return if fed_actor.nil? || fed_actor.blocked?
      InboxService.process(fed_actor, activity)
    end
  end
end
