module Federation
  # Runs the business half of an inbound activity. Signature verification
  # already happened in the request; the inbox 202s fast and defers here so
  # remote senders never time out on our processing.
  #
  # The job owns the ledger's terminal state: processed/ignored on success,
  # failed once the retries run out. A "failed" row is retryable — the inbox
  # re-runs it when the remote redelivers (FedInboundActivity.record!).
  class InboundJob < ApplicationJob
    queue_as :federation

    retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
      _actor_id, activity = job.arguments
      FedInboundActivity.mark!(activity["id"], "failed")
      Rails.logger.error("[fed] inbound #{activity["type"]} #{activity["id"]} failed: #{error.message}")
    end

    def perform(fed_actor_id, activity)
      fed_actor = FedActor.find_by(id: fed_actor_id)
      if fed_actor.nil? || fed_actor.blocked?
        FedInboundActivity.mark!(activity["id"], "ignored")
        return
      end
      result = InboxService.process(fed_actor, activity)
      FedInboundActivity.mark!(activity["id"], result == :ignored ? "ignored" : "processed")
    end
  end
end
