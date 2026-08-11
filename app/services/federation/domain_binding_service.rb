require "resolv"

module Federation
  # Custom-domain binding for groups (PLAN §9.4). The domain is a *signature*,
  # not an identity: acct moves onto it, the actor id never does — so binding
  # and unbinding are both lossless.
  #
  # Ownership is proved with a DNS TXT record rather than by fetching the
  # domain. Two reasons: an HTTP probe from the server is an SSRF surface and
  # a rebinding target, and it can only prove "this domain routes here" — which
  # a co-tenant on the same instance could also arrange. A TXT record under the
  # domain proves control of the domain itself, which is the claim being made.
  #
  # Routing (DNS A/CNAME + a TLS route on the instance) is a separate, ops-side
  # step. Verification does not check it: a group may prove ownership before ops
  # wires the route, and the binding is harmless until then — WebFinger
  # delegation only answers on a host that actually reaches us.
  class DomainBindingService
    class Error < StandardError; end

    CHALLENGE_PREFIX = "_sola-challenge"
    TXT_PREFIX = "sola-domain-verification="
    # A hostname, at least two labels, no scheme/port/path.
    HOSTNAME = /\A(?=.{4,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}\z/
    RESOLV_TIMEOUT = 5

    # Step 1 — claim a domain and mint the challenge. Idempotent: re-claiming
    # the same domain keeps the token, so a user who lost the page can come
    # back to the same DNS record instead of having to redo it.
    def self.claim!(group, domain)
      domain = normalize(domain)
      raise Error, "domain must be a bare hostname like hi.example.org" unless domain.match?(HOSTNAME)
      raise Error, "that domain is this instance's own host" if reserved?(domain)
      if Group.where.not(id: group.id).exists?(custom_domain: domain)
        raise Error, "that domain is already bound to another group"
      end

      if group.custom_domain_pending != domain || group.custom_domain_token.blank?
        group.update!(custom_domain_pending: domain,
                      custom_domain_token: SecureRandom.alphanumeric(32))
      end
      instructions(group)
    end

    # Step 2 — verify the TXT record and bind. Only here does custom_domain
    # (the field WebFinger reads) change.
    def self.verify!(group)
      domain = group.custom_domain_pending.to_s
      raise Error, "no domain claimed" if domain.blank?
      raise Error, "that domain is this instance's own host" if reserved?(domain)
      if Group.where.not(id: group.id).exists?(custom_domain: domain)
        raise Error, "that domain is already bound to another group"
      end

      expected = "#{TXT_PREFIX}#{group.custom_domain_token}"
      found = txt_records("#{CHALLENGE_PREFIX}.#{domain}")
      unless found.include?(expected)
        raise Error, "TXT record not found yet. Looked up #{CHALLENGE_PREFIX}.#{domain}" \
                     "#{found.any? ? " and found #{found.size} record(s), none matching" : ""}. " \
                     "DNS changes can take a few minutes to propagate."
      end

      group.update!(custom_domain: domain, custom_domain_verified_at: Time.current,
                    custom_domain_pending: nil, custom_domain_token: nil)
      status(group)
    end

    # Unbind. The actor id never moved here, so nothing breaks except the
    # vanity acct — peers that cached `name@domain` re-resolve to the canonical
    # host on their next WebFinger.
    def self.unbind!(group)
      group.update!(custom_domain: nil, custom_domain_verified_at: nil,
                    custom_domain_pending: nil, custom_domain_token: nil)
      status(group)
    end

    def self.status(group)
      base = {
        domain: group.custom_domain,
        verified_at: group.custom_domain_verified_at,
        acct: group.custom_domain.present? ? "#{group.name}@#{group.custom_domain}" : Urls.acct(group),
        canonical_acct: "#{group.name}@#{Urls.host}",
        actor_uri: Urls.actor_url(group),
        state: group.custom_domain.present? ? "bound" : (group.custom_domain_pending.present? ? "pending" : "none")
      }
      group.custom_domain_pending.present? ? base.merge(instructions(group)) : base
    end

    def self.instructions(group)
      domain = group.custom_domain_pending
      {
        state: "pending",
        pending_domain: domain,
        dns_challenge: {
          type: "TXT",
          name: "#{CHALLENGE_PREFIX}.#{domain}",
          value: "#{TXT_PREFIX}#{group.custom_domain_token}"
        },
        # Ownership proof and traffic routing are different things; say so,
        # because a user who only adds the TXT record will verify successfully
        # and then wonder why the domain shows nothing.
        dns_routing: {type: "CNAME/A", name: domain, value: Urls.host},
        note: "The TXT record proves you own the domain. Pointing the domain at " \
              "#{Urls.host} is what makes it serve — ask the instance operator to " \
              "add the route."
      }
    end

    def self.normalize(domain)
      domain.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").split("/").first.to_s.split(":").first.to_s
    end

    # Binding the instance's own host would hijack every actor on it.
    def self.reserved?(domain)
      [Urls.host, URI.parse(ENV.fetch("WEB_URL", "https://app.sola.day")).host].compact.include?(domain)
    end

    def self.txt_records(name)
      Resolv::DNS.open do |dns|
        dns.timeouts = RESOLV_TIMEOUT
        dns.getresources(name, Resolv::DNS::Resource::IN::TXT).map { |r| r.strings.join }
      end
    rescue Resolv::ResolvError, Resolv::ResolvTimeout, SocketError => e
      Rails.logger.info("[fed] domain verification lookup failed for #{name}: #{e.class}")
      []
    end
  end
end
