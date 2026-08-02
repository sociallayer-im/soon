module Federation
  # Scheduled entry point for follow reconciliation (INTEROP §10.3). Daily,
  # off-peak: each run touches at most BATCH edges and only network-fetches
  # actors whose cache has gone stale, so it coexists with the single
  # GoodJob thread.
  class ReconciliationJob < ApplicationJob
    queue_as :federation

    def perform
      return unless Federation.enabled?
      FollowReconciliationService.run
    end
  end
end
