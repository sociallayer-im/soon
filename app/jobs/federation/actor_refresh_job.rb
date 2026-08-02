module Federation
  # Background refresh of a cached actor (P1-18): metadata like inbox and
  # sharedInbox drifts on the remote side, and a successfully-verifying actor
  # would otherwise never be re-fetched — deliveries keep hitting an inbox
  # that moved. Best-effort: failures are already negative-cached upstream.
  class ActorRefreshJob < ApplicationJob
    queue_as :federation

    def perform(uri)
      ActorFetchService.fetch!(uri)
    rescue ActorFetchService::FetchError, HttpClient::Error
      # the negative cache and per-domain budget stop refresh storms
    end
  end
end
