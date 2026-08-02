# Per-domain rolling counters: observability and the 7-day unavailability
# circuit breaker (Mastodon's DeliveryFailureTracker semantics — continuous
# failure days, reset by any success in either direction).
class FedDomainStat < ApplicationRecord
  UNAVAILABLE_AFTER_DAYS = 7

  def self.for(domain)
    domain = FedDomainPolicy.canonicalize(domain)
    find_by(domain: domain) || create!(domain: domain)
  rescue ActiveRecord::RecordNotUnique
    find_by!(domain: domain)
  end

  # Counters use single-statement SQL increments: the read-modify-write via
  # update! lost counts whenever two requests raced (P2-2 lost update).
  def self.record_delivery!(domain, success:, error: nil)
    stat = self.for(domain)
    if success
      where(id: stat.id).update_all(["delivered_count = delivered_count + 1, " \
        "last_success_at = ?, unavailable_since = NULL, last_error = NULL", Time.current])
    else
      where(id: stat.id).update_all(["failed_count = failed_count + 1, last_failure_at = ?, " \
        "unavailable_since = COALESCE(unavailable_since, ?), last_error = ?",
        Time.current, Date.current, error&.truncate(255)])
    end
  end

  def self.record_inbound!(domain, rejected: false)
    stat = self.for(domain)
    if rejected
      where(id: stat.id).update_all("inbound_rejected_count = inbound_rejected_count + 1")
    else
      # any legitimate inbound contact proves the domain is alive
      where(id: stat.id).update_all("inbound_count = inbound_count + 1, unavailable_since = NULL")
    end
  end

  def self.unavailable?(domain)
    since = self.for(domain).unavailable_since
    since.present? && since <= Date.current - UNAVAILABLE_AFTER_DAYS
  end
end
