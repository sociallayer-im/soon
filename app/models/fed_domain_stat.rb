# Per-domain rolling counters: observability and the 7-day unavailability
# circuit breaker (Mastodon's DeliveryFailureTracker semantics — continuous
# failure days, reset by any success in either direction).
class FedDomainStat < ApplicationRecord
  UNAVAILABLE_AFTER_DAYS = 7

  def self.for(domain)
    domain = domain.to_s.downcase
    find_by(domain: domain) || create!(domain: domain)
  rescue ActiveRecord::RecordNotUnique
    find_by!(domain: domain)
  end

  def self.record_delivery!(domain, success:, error: nil)
    stat = self.for(domain)
    if success
      stat.update!(delivered_count: stat.delivered_count + 1,
                   last_success_at: Time.current, unavailable_since: nil, last_error: nil)
    else
      stat.update!(failed_count: stat.failed_count + 1,
                   last_failure_at: Time.current,
                   unavailable_since: stat.unavailable_since || Date.current,
                   last_error: error&.truncate(255))
    end
  end

  def self.record_inbound!(domain, rejected: false)
    stat = self.for(domain)
    if rejected
      stat.update!(inbound_rejected_count: stat.inbound_rejected_count + 1)
    else
      # any legitimate inbound contact proves the domain is alive
      stat.update!(inbound_count: stat.inbound_count + 1, unavailable_since: nil)
    end
  end

  def self.unavailable?(domain)
    since = self.for(domain).unavailable_since
    since.present? && since <= Date.current - UNAVAILABLE_AFTER_DAYS
  end
end
