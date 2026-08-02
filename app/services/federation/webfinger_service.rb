module Federation
  # Resolves acct:user@host to a cached remote actor, following the same steps
  # Mastodon does: webfinger, take the rel=self link whose type is an AP one,
  # then fetch and validate the actor document.
  class WebfingerService
    class Error < StandardError; end

    AP_TYPES = ["application/activity+json",
                'application/ld+json; profile="https://www.w3.org/ns/activitystreams"'].freeze

    def self.resolve!(acct)
      name, host = parse(acct)
      raise Error, "not an acct" if name.blank? || host.blank?

      raise Error, "domain #{host} not allowed" unless FedDomainPolicy.domain_allowed?(host)

      url = "https://#{host}/.well-known/webfinger?resource=acct:#{name}@#{host}"
      res = HttpClient.get(url, headers: {"Accept" => "application/jrd+json, application/json"})
      raise Error, "webfinger HTTP #{res.status}" unless res.success?

      doc = JSON.parse(res.body)
      link = Array(doc["links"]).find { |l|
        l.is_a?(Hash) && l["rel"] == "self" && AP_TYPES.include?(l["type"])
      }
      raise Error, "no ActivityPub self link" if link.nil? || link["href"].blank?

      ActorFetchService.fetch!(link["href"])
    rescue JSON::ParserError => e
      raise Error, "unparseable webfinger response: #{e.message}"
    end

    def self.parse(acct)
      cleaned = acct.to_s.strip.delete_prefix("@").delete_prefix("acct:")
      name, host = cleaned.split("@", 2)
      [name, host&.downcase]
    end
  end
end
