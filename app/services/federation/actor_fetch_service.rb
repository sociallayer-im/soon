module Federation
  # Fetches and caches remote actors. Validation is Mastodon's acceptance
  # rules run in reverse (INTEROP §2.2): body id must equal the fetched URI,
  # content-type must be AP, @context must include AS, inbox is mandatory.
  # GETs are signed with the instance actor so authorized-fetch peers answer.
  class ActorFetchService
    SUPPORTED_TYPES = %w[Person Group Organization Service Application].freeze
    AP_CONTENT_TYPES = ["application/activity+json", "application/ld+json"].freeze

    class FetchError < StandardError; end

    # An inbox POST naming an unknown keyId makes us fetch that actor. Without
    # a brake, N forged keyIds become N outbound requests — the inbox becomes
    # an amplifier, and each fetch also holds a request thread for up to the
    # HTTP timeout. So a failed fetch is remembered briefly and not retried,
    # and discovery is rate limited per domain (the same shape as Mastodon's
    # per-IP stoplight and its DISCOVERIES_PER_REQUEST cap).
    NEGATIVE_TTL = 5.minutes

    @failures = {}
    @failures_mutex = Mutex.new

    def self.recently_failed?(uri)
      @failures_mutex.synchronize do
        expires = @failures[uri]
        next false if expires.nil?
        next true if expires > Time.current
        @failures.delete(uri)
        false
      end
    end

    def self.remember_failure(uri)
      @failures_mutex.synchronize do
        @failures.delete_if { |_, exp| exp <= Time.current } if @failures.size > 5_000
        @failures[uri] = Time.current + NEGATIVE_TTL
      end
    end

    def self.forget_failure(uri)
      @failures_mutex.synchronize { @failures.delete(uri) }
    end

    # test hook
    def self.reset_failures!
      @failures_mutex.synchronize { @failures.clear }
    end

    # key_id → [FedActor, public_key_pem]; refetch: true forces a refresh
    # (used once after a failed verification, KY-5 semantics).
    def self.resolve_key(key_id, refetch: false)
      actor_uri = key_id.split("#").first.delete_suffix("/publickey")
      actor = FedActor.find_by(key_id: key_id) || FedActor.find_by(uri: actor_uri)
      actor = fetch!(actor_uri) if actor.nil? || actor.public_key_pem.blank? || refetch
      raise FetchError, "no public key for #{key_id}" if actor.public_key_pem.blank?
      # a verifying-but-stale actor gets an ASYNC refresh: metadata (inbox,
      # sharedInbox) drifts remotely and no failure would ever trigger a
      # refetch on this path (P1-18). Never blocks the request.
      if actor.stale? && RateLimiter.allow?(:refresh, actor.domain)
        ActorRefreshJob.perform_later(actor.uri)
      end
      actor
    end

    def self.fetch!(uri)
      domain = FedDomainPolicy.canonicalize(URI.parse(uri).host)
      raise FetchError, "domain #{domain} not allowed" unless FedDomainPolicy.domain_allowed?(domain)
      raise FetchError, "#{uri} failed recently, not retrying" if recently_failed?(uri)
      unless RateLimiter.allow?(:discovery, domain)
        raise FetchError, "discovery rate limit reached for #{domain}"
      end
      # Per-domain budgets alone are defeated by rotating throwaway domains —
      # every fetch also draws from ONE global pool (P1-15).
      unless RateLimiter.allow?(:discovery_global, "all")
        raise FetchError, "global discovery rate limit reached"
      end

      begin
        doc = signed_get(uri)
        validate!(doc, uri)
      rescue FetchError, HttpClient::Error
        remember_failure(uri)
        raise
      rescue URI::Error, TypeError, NoMethodError => e
        # a hostile document must become a cacheable failure, not a 500 and
        # not an uncached path that re-fetches on every bad signature (P1-12)
        remember_failure(uri)
        raise FetchError, "malformed actor document: #{e.class}"
      end
      forget_failure(uri)
      upsert(doc, uri, domain)
    end

    def self.signed_get(uri)
      key = FedInstanceKey.current
      headers = HttpSignature.sign(method: :get, url: uri,
                                   key_id: Urls.instance_key_id, private_key: key.private_key)
      headers["Accept"] = "application/activity+json, application/ld+json"
      response = HttpClient.get(uri, headers: headers)
      raise FetchError, "HTTP #{response.status} fetching #{uri}" unless response.success?
      content_type = response.headers["content-type"].to_s
      unless AP_CONTENT_TYPES.any? { |t| content_type.include?(t) }
        raise FetchError, "non-AP content-type #{content_type}"
      end
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise FetchError, "unparseable actor document: #{e.message}"
    end

    def self.validate!(doc, uri)
      raise FetchError, "actor document is not an object" unless doc.is_a?(Hash)
      raise FetchError, "id #{doc['id']} != fetched uri #{uri}" unless doc["id"] == uri
      context = Array(doc["@context"]).flatten
      unless context.include?(JsonLd::AS) || doc["@context"] == JsonLd::AS
        raise FetchError, "missing activitystreams @context"
      end
      type = Array(doc["type"]).find { |t| SUPPORTED_TYPES.include?(t) }
      raise FetchError, "unsupported actor type #{doc['type']}" if type.nil?
      raise FetchError, "actor inbox is not an http(s) URL" unless http_url?(doc["inbox"])

      # Only a complete, internally consistent key may enter the cache: a
      # cached actor with a broken key would fail resolve_key on every
      # request and re-fetch forever, bypassing the negative cache (P1-12).
      key = doc["publicKey"]
      key = key.first if key.is_a?(Array)
      raise FetchError, "actor has no publicKey object" unless key.is_a?(Hash)
      raise FetchError, "publicKey.id is not a URL" unless http_url?(key["id"])
      unless URI.parse(key["id"].split("#").first).host == URI.parse(uri).host
        raise FetchError, "publicKey.id is on a different host than the actor"
      end
      owner = key["owner"]
      raise FetchError, "publicKey.owner != actor id" if owner.present? && owner != uri
      pem = key["publicKeyPem"]
      raise FetchError, "publicKeyPem missing" unless pem.is_a?(String)
      begin
        OpenSSL::PKey::RSA.new(pem)
      rescue OpenSSL::PKey::PKeyError
        raise FetchError, "publicKeyPem is not a valid RSA key"
      end
    end

    def self.http_url?(value)
      value.is_a?(String) && value.match?(%r{\Ahttps?://\S+\z})
    end

    def self.upsert(doc, uri, domain)
      key = doc["publicKey"]
      key = key.first if key.is_a?(Array)
      key = {} unless key.is_a?(Hash)
      actor = FedActor.find_or_initialize_by(uri: uri)
      actor.assign_attributes(
        domain: domain,
        actor_type: Array(doc["type"]).find { |t| SUPPORTED_TYPES.include?(t) },
        preferred_username: doc["preferredUsername"],
        name: doc["name"],
        summary: doc["summary"],
        icon_url: doc.dig("icon", "url"),
        inbox_url: doc["inbox"],
        shared_inbox_url: doc.dig("endpoints", "sharedInbox") || doc["sharedInbox"],
        outbox_url: doc["outbox"],
        followers_url: doc["followers"],
        public_key_pem: key["publicKeyPem"],
        key_id: key["id"],
        # Move semantics: both sides of the mutual attestation live on the
        # actor document, so they have to be captured here to be checkable.
        moved_to: doc["movedTo"].is_a?(String) ? doc["movedTo"] : nil,
        also_known_as: Array(doc["alsoKnownAs"]).grep(String),
        last_fetched_at: Time.current,
        raw: doc
      )
      actor.save!
      actor
    rescue ActiveRecord::RecordNotUnique
      FedActor.find_by!(uri: uri)
    end
  end
end
