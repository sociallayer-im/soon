# Per-domain federation policy. Two modes (FEDERATION_MODE env):
#   open      — federate with everyone except policy=blocked (default)
#   allowlist — federate ONLY with policy=allowed domains
# Enforcement is a table lookup on every path (inbox, outbound expansion,
# actor fetch) so changes take effect without a restart.
class FedDomainPolicy < ApplicationRecord
  POLICIES = %w[blocked allowed].freeze
  MODES = %w[open allowlist].freeze

  validates :domain, presence: true, uniqueness: true
  validates :policy, inclusion: {in: POLICIES}

  # A typo'd FEDERATION_MODE must fail CLOSED (allowlist), not silently open
  # federation to the world.
  def self.mode
    m = ENV.fetch("FEDERATION_MODE", "open")
    MODES.include?(m) ? m : "allowlist"
  end

  # One canonical form everywhere: policy rows, stats and checks must agree
  # on what "the domain" is or a block becomes case-/dot-sensitive.
  def self.canonicalize(domain)
    domain.to_s.downcase.chomp(".")
  end

  # The single question every enforcement point asks.
  def self.domain_allowed?(domain)
    domain = canonicalize(domain)
    if mode == "allowlist"
      where(domain: domain, policy: "allowed").exists?
    else
      !where(domain: domain, policy: "blocked").exists?
    end
  end

  def self.blocked_domains = where(policy: "blocked").select(:domain)
  def self.allowed_domains = where(policy: "allowed").select(:domain)
end
