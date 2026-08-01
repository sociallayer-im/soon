# Per-domain federation policy. Two modes (FEDERATION_MODE env):
#   open      — federate with everyone except policy=blocked (default)
#   allowlist — federate ONLY with policy=allowed domains
# Enforcement is a table lookup on every path (inbox, outbound expansion,
# actor fetch) so changes take effect without a restart.
class FedDomainPolicy < ApplicationRecord
  POLICIES = %w[blocked allowed].freeze

  validates :domain, presence: true, uniqueness: true
  validates :policy, inclusion: {in: POLICIES}

  def self.mode
    ENV.fetch("FEDERATION_MODE", "open")
  end

  # The single question every enforcement point asks.
  def self.domain_allowed?(domain)
    domain = domain.to_s.downcase
    if mode == "allowlist"
      where(domain: domain, policy: "allowed").exists?
    else
      !where(domain: domain, policy: "blocked").exists?
    end
  end
end
