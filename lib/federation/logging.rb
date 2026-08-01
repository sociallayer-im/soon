module Federation
  # One structured line per federation event — the raw ledger for on-call
  # greps and postmortem reconciliation (design/FEDERATION_PLAN.md §2.9).
  module Logging
    module_function

    def log(direction, type, domain: nil, status: nil, **extra)
      fields = {direction: direction, type: type, domain: domain, status: status}
               .merge(extra).compact
               .map { |k, v| "#{k}=#{v}" }.join(" ")
      Rails.logger.info("[fed] #{fields}")
    end
  end
end
