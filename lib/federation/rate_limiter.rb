module Federation
  # Flood control, not billing (design/FEDERATION_PLAN.md §2.10). Fixed
  # windows over an in-process counter — the deployment is a single Puma
  # process (WEB_CONCURRENCY unset, by hard constraint), so process-local IS
  # instance-global, and it works identically under test's :null_store cache.
  module RateLimiter
    LIMITS = {
      domain: [120, 60],   # activities per domain per minute
      follow: [10, 60],    # per remote actor
      join: [10, 60],
      note: [6, 60],
      actor: [60, 60],     # any activity per remote actor
      # Outbound actor fetches per domain. Every unknown keyId in an inbox POST
      # costs one, so this is what stops a flood of forged keyIds from turning
      # our inbox into an amplifier.
      discovery: [30, 60],
      # One global pool over ALL domains: per-domain budgets are defeated by
      # rotating throwaway (sub)domains, each arriving with a fresh budget.
      discovery_global: [300, 60],
      # background refreshes of a stale-but-working actor, per domain
      refresh: [2, 300]
    }.freeze

    @counters = {}
    @mutex = Mutex.new

    module_function

    def allow?(kind, key)
      limit, window = LIMITS.fetch(kind)
      bucket = Time.now.to_i / window
      @mutex.synchronize do
        # drop expired buckets so the map stays bounded
        @counters.delete_if { |(_, _, b), _| b < bucket - 1 } if @counters.size > 10_000
        k = [kind, key.to_s, bucket]
        @counters[k] = @counters.fetch(k, 0) + 1
        @counters[k] <= limit
      end
    end

    def retry_after(kind)
      LIMITS.fetch(kind).last
    end

    # test hook
    def reset!
      @mutex.synchronize { @counters.clear }
    end
  end
end
